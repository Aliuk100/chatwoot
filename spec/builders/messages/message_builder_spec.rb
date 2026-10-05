require 'rails_helper'

describe Messages::MessageBuilder do
  subject(:message_builder) { described_class.new(user, conversation, params).perform }

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:inbox_member) { create(:inbox_member, inbox: inbox, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account) }
  let(:message_for_reply) { create(:message, conversation: conversation) }
  let(:params) do
    ActionController::Parameters.new({
                                       content: 'test'
                                     })
  end

  describe '#perform' do
    it 'creates a message' do
      message = message_builder
      expect(message.content).to eq params[:content]
    end

    context 'with a Messages360 historical import' do
      let(:api_channel) { create(:channel_api, account: account) }
      let(:inbox) { create(:inbox, channel: api_channel, account: account) }
      let(:conversation) do
        create(:conversation, inbox: inbox, account: account, custom_attributes: { 'os360_channel' => 'ebay' })
      end
      let(:provider_timestamp) { '2024-04-05T12:34:56Z' }
      let(:historical_attributes) do
        {
          messages360_import_only: true,
          messages360_channel: 'ebay',
          messages360_message_id: 'provider-message-1',
          messages360_conversation_id: 'provider-conversation-1'
        }
      end
      let(:params) do
        ActionController::Parameters.new(
          content: 'historical message',
          message_type: 'incoming',
          source_id: 'm360-msg-provider-message-1',
          external_created_at: provider_timestamp,
          content_attributes: historical_attributes
        )
      end

      it 'persists and returns the provider timestamp without using import time' do
        message = message_builder

        expect(message.created_at).to eq(Time.rfc3339(provider_timestamp))
        expect(message.content_attributes['external_created_at']).to eq(provider_timestamp)
        expect(message.content_attributes['messages360_import_only']).to be(true)
        expect(conversation.reload.last_activity_at).to eq(message.created_at)
      end

      it 'keeps chronology and recency correct when messages arrive newest first' do
        newer_timestamp = '2024-04-05T12:34:56Z'
        older_timestamp = '2024-04-04T12:34:56Z'
        newer_message = message_builder
        older_params = params.deep_dup
        older_params[:source_id] = 'm360-msg-provider-message-2'
        older_params[:external_created_at] = older_timestamp
        older_params[:content_attributes][:messages360_message_id] = 'provider-message-2'
        older_message = described_class.new(user, conversation, older_params).perform

        expect(conversation.messages.pluck(:id)).to eq([older_message.id, newer_message.id])
        expect(conversation.reload.last_activity_at).to eq(Time.rfc3339(newer_timestamp))
      end

      it 'does not regress an active conversation during historical backfill' do
        live_message = create(:message, conversation: conversation, account: account, inbox: inbox, created_at: 1.hour.ago)

        message_builder

        expect(conversation.reload.last_activity_at).to eq(live_message.reload.created_at)
      end

      it 'does not move an old conversation above a genuinely recent conversation' do
        recent_conversation = create(:conversation, inbox: inbox, account: account)
        recent_message = create(:message, conversation: recent_conversation, account: account, inbox: inbox)

        message_builder

        ordered_ids = Conversation.where(id: [conversation.id, recent_conversation.id])
                                  .sort_on_last_activity_at
                                  .pluck(:id)
        expect(ordered_ids).to eq([recent_conversation.id, conversation.id])
        expect(recent_conversation.reload.last_activity_at).to eq(recent_message.reload.created_at)
      end

      it 'lets a genuinely new live message advance conversation recency normally' do
        message_builder
        live_message = create(:message, conversation: conversation, account: account, inbox: inbox)

        expect(conversation.reload.last_activity_at).to eq(live_message.reload.created_at)
      end

      it 'preserves historical side-effect state and does not enqueue a provider send' do
        original_waiting_since = 2.hours.ago.change(usec: 0)
        conversation.update!(status: :resolved)
        conversation.update!(waiting_since: original_waiting_since)
        original_contact_activity = conversation.contact.last_activity_at
        user
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        allow(SendReplyJob).to receive(:perform_later)
        allow(MessageTemplates::HookExecutionService).to receive(:new)

        message_builder

        expect(conversation.reload).to be_resolved
        expect(conversation.waiting_since).to eq(original_waiting_since)
        expect(conversation.first_reply_created_at).to be_nil
        expect(conversation.contact.reload.last_activity_at).to eq(original_contact_activity)
        expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
        expect(SendReplyJob).not_to have_received(:perform_later)
        expect(MessageTemplates::HookExecutionService).not_to have_received(:new)
      end

      it 'does not send imported outgoing history' do
        params[:message_type] = 'outgoing'
        allow(SendReplyJob).to receive(:perform_later)

        message_builder

        expect(SendReplyJob).not_to have_received(:perform_later)
      end

      it 'does not create notifications for historical imports' do
        user
        conversation

        expect { message_builder }.not_to change(Notification, :count)
      end

      it 'rejects an invalid provider timestamp without creating a message' do
        params[:external_created_at] = 'not-a-timestamp'

        expect { message_builder }
          .to raise_error(ArgumentError, 'external_created_at must be a valid RFC3339 timestamp for Messages360 historical imports')
        expect(conversation.messages.count).to eq(0)
      end

      it 'rejects a missing provider timestamp without creating a message' do
        params.delete(:external_created_at)

        expect { message_builder }
          .to raise_error(ArgumentError, 'external_created_at must be a valid RFC3339 timestamp for Messages360 historical imports')
        expect(conversation.messages.count).to eq(0)
      end

      it 'keeps the normal external_created_at behavior for non-Messages360 messages' do
        params[:source_id] = 'another-source'
        params[:content_attributes].delete(:messages360_import_only)

        message = message_builder

        expect(message.created_at).to be_within(5.seconds).of(Time.current)
        # The base builder leaves this accessor unset for this incoming-message payload.
        expect(message.external_created_at).to be_nil
        expect(message.content_attributes['messages360_import_only']).to be_nil
      end

      [nil, false, 'true'].each do |marker|
        it "keeps identity-only traffic ordinary with marker #{marker.inspect}" do
          conversation.contact.update!(custom_attributes: { messages360_import_only: true })
          params[:content_attributes][:messages360_import_only] = marker
          params[:external_created_at] = 'invalid'

          expect(message_builder.created_at).to be_within(5.seconds).of(Time.current)
        end

        it "accepts a missing provider timestamp with marker #{marker.inspect}" do
          params[:content_attributes][:messages360_import_only] = marker
          params.delete(:external_created_at)

          expect(message_builder.created_at).to be_within(5.seconds).of(Time.current)
        end
      end

      it 'does not let a delayed older historical callback overwrite live recency' do
        historical_message = message_builder
        live_message = create(:message, conversation: conversation, account: account, inbox: inbox)

        historical_message.send(:set_conversation_activity)
        historical_message.send(:set_conversation_activity)

        expect(conversation.reload.last_activity_at).to eq(live_message.reload.created_at)
        expect(conversation.last_activity_at).to eq(conversation.messages.maximum(:created_at))
      end

      context 'with concurrent committed callbacks' do
        self.use_transactional_tests = false

        after do
          tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]
          quoted_tables = tables.map { |table| ActiveRecord::Base.connection.quote_table_name(table) }
          ActiveRecord::Base.connection.execute("TRUNCATE #{quoted_tables.join(', ')} CASCADE")
        end

        %w[live historical].each do |kind|
          it "serializes an older historical callback against newer #{kind} activity" do
            older = message_builder
            newer_attributes = kind == 'historical' ? older.content_attributes : {}
            newer = create(
              :message,
              conversation: conversation, account: account, inbox: inbox,
              source_id: kind == 'historical' ? 'm360-msg-newer' : 'live-newer',
              created_at: Time.utc(2025, 1, 1), content_attributes: newer_attributes
            )
            locked = Queue.new
            release = Queue.new
            attempting = Queue.new
            older_conversation = Conversation.find(conversation.id)
            allow(older).to receive(:conversation).and_return(older_conversation)
            newer_conversation = Conversation.find(conversation.id)
            allow(Conversation).to receive(:find).with(conversation.id).and_return(older_conversation, newer_conversation)
            allow(newer).to receive(:conversation).and_return(newer_conversation)
            allow(older_conversation).to receive(:with_lock).and_wrap_original do |method, &block|
              method.call do
                locked.push(true)
                release.pop
                block.call
              end
            end
            allow(newer_conversation).to receive(:with_lock).and_wrap_original do |method, &block|
              attempting.push(true)
              method.call(&block)
            end

            older_thread = Thread.new do
              ActiveRecord::Base.connection_pool.with_connection { older.send(:set_conversation_activity) }
            end
            Timeout.timeout(10) { locked.pop }
            newer_thread = Thread.new do
              ActiveRecord::Base.connection_pool.with_connection { newer.send(:set_conversation_activity) }
            end
            Timeout.timeout(10) { attempting.pop }
            release.push(true)
            Timeout.timeout(10) { [older_thread, newer_thread].each(&:value) }

            expect(conversation.reload.last_activity_at).to eq(newer.reload.created_at)
            expect(conversation.last_activity_at).to eq(conversation.messages.maximum(:created_at))
          ensure
            release&.push(true)
            [older_thread, newer_thread].compact.each { |thread| thread.join(10) }
          end
        end
      end
    end
  end

  describe '#content_attributes' do
    context 'when content_attributes is a JSON string' do
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           content_attributes: "{\"in_reply_to\":#{message_for_reply.id}}"
                                         })
      end

      it 'parses content_attributes from JSON string' do
        message = described_class.new(user, conversation, params).perform
        expect(message.content_attributes).to include(in_reply_to: message_for_reply.id)
      end
    end

    context 'when content_attributes is a hash' do
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           content_attributes: { in_reply_to: message_for_reply.id }
                                         })
      end

      it 'uses content_attributes as provided' do
        message = described_class.new(user, conversation, params).perform
        expect(message.content_attributes).to include(in_reply_to: message_for_reply.id)
      end
    end

    context 'when content_attributes is absent' do
      let(:params) do
        ActionController::Parameters.new({ content: 'test' })
      end

      it 'defaults to an empty hash' do
        message = message_builder
        expect(message.content_attributes).to eq({})
      end
    end

    context 'when content_attributes is nil' do
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           content_attributes: nil
                                         })
      end

      it 'defaults to an empty hash' do
        message = message_builder
        expect(message.content_attributes).to eq({})
      end
    end

    context 'when content_attributes is an invalid JSON string' do
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           content_attributes: 'invalid_json'
                                         })
      end

      it 'defaults to an empty hash' do
        message = message_builder
        expect(message.content_attributes).to eq({})
      end
    end
  end

  describe '#perform when message_type is incoming' do
    context 'when channel is not api' do
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           message_type: 'incoming'
                                         })
      end

      it 'creates throws error when channel is not api' do
        expect { message_builder }.to raise_error 'Incoming messages are only allowed in Api inboxes'
      end
    end

    context 'when channel is api' do
      let(:channel_api) { create(:channel_api, account: account) }
      let(:conversation) { create(:conversation, inbox: channel_api.inbox, account: account) }
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           message_type: 'incoming'
                                         })
      end

      it 'creates message when channel is api' do
        message = message_builder
        expect(message.message_type).to eq params[:message_type]
      end
    end

    context 'when attachment messages' do
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           attachments: [Rack::Test::UploadedFile.new('spec/assets/avatar.png', 'image/png')]
                                         })
      end

      it 'creates message with attachments' do
        message = message_builder
        expect(message.attachments.first.file_type).to eq 'image'
      end

      context 'when DIRECT_UPLOAD_ENABLED' do
        let(:params) do
          ActionController::Parameters.new({
                                             content: 'test',
                                             attachments: [get_blob_for('spec/assets/avatar.png', 'image/png').signed_id]
                                           })
        end

        it 'creates message with attachments' do
          message = message_builder
          expect(message.attachments.first.file_type).to eq 'image'
        end
      end
    end

    context 'when is_voice_message is true' do
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           attachments: [Rack::Test::UploadedFile.new('spec/assets/sample.ogg', 'audio/ogg')],
                                           is_voice_message: true
                                         })
      end

      it 'sets is_voice_message in attachment meta' do
        message = message_builder
        expect(message.attachments.first.meta).to include('is_voice_message' => true)
      end
    end

    context 'when is_voice_message is not provided' do
      let(:params) do
        ActionController::Parameters.new({
                                           content: 'test',
                                           attachments: [Rack::Test::UploadedFile.new('spec/assets/avatar.png', 'image/png')]
                                         })
      end

      it 'does not set is_voice_message in attachment meta' do
        message = message_builder
        expect(message.attachments.first.meta).not_to include('is_voice_message')
      end
    end

    context 'when email channel messages' do
      let!(:channel_email) { create(:channel_email, account: account) }
      let(:inbox_member) { create(:inbox_member, inbox: channel_email.inbox) }
      let(:conversation) { create(:conversation, inbox: channel_email.inbox, account: account) }
      let(:params) do
        ActionController::Parameters.new({ cc_emails: 'test_cc_mail@test.com', bcc_emails: 'test_bcc_mail@test.com' })
      end

      it 'creates message with content_attributes for cc and bcc email addresses' do
        message = message_builder

        expect(message.content_attributes[:cc_emails]).to eq [params[:cc_emails]]
        expect(message.content_attributes[:bcc_emails]).to eq [params[:bcc_emails]]
      end

      it 'does not create message with wrong cc and bcc email addresses' do
        params = ActionController::Parameters.new({ cc_emails: 'test.com', bcc_emails: 'test_bcc.com' })
        expect { described_class.new(user, conversation, params).perform }.to raise_error 'Invalid email address'
      end

      it 'strips off whitespace before saving cc_emails and bcc_emails' do
        cc_emails = ' test1@test.com , test2@test.com, test3@test.com'
        bcc_emails = 'test1@test.com,test2@test.com, test3@test.com '
        params = ActionController::Parameters.new({ cc_emails: cc_emails, bcc_emails: bcc_emails })

        message = described_class.new(user, conversation, params).perform

        expect(message.content_attributes[:cc_emails]).to eq ['test1@test.com', 'test2@test.com', 'test3@test.com']
        expect(message.content_attributes[:bcc_emails]).to eq ['test1@test.com', 'test2@test.com', 'test3@test.com']
      end

      context 'when custom email content is provided' do
        it 'creates message with custom HTML email content' do
          params = ActionController::Parameters.new({
                                                      content: 'Regular message content',
                                                      email_html_content: '<p>Custom <strong>HTML</strong> content</p>'
                                                    })

          message = described_class.new(user, conversation, params).perform

          expect(message.content_attributes.dig('email', 'html_content', 'full')).to eq '<p>Custom <strong>HTML</strong> content</p>'
          expect(message.content_attributes.dig('email', 'html_content', 'reply')).to eq '<p>Custom <strong>HTML</strong> content</p>'
          expect(message.content_attributes.dig('email', 'text_content', 'full')).to eq 'Regular message content'
          expect(message.content_attributes.dig('email', 'text_content', 'reply')).to eq 'Regular message content'
        end

        it 'does not process custom email content for private messages' do
          params = ActionController::Parameters.new({
                                                      content: 'Regular message content',
                                                      email_html_content: '<p>Custom HTML content</p>',
                                                      private: true
                                                    })

          message = described_class.new(user, conversation, params).perform

          expect(message.content_attributes.dig('email', 'html_content')).to be_nil
          expect(message.content_attributes.dig('email', 'text_content')).to be_nil
        end

        it 'falls back to default behavior when no custom email content is provided' do
          params = ActionController::Parameters.new({
                                                      content: 'Regular **markdown** content'
                                                    })

          message = described_class.new(user, conversation, params).perform

          expect(message.content_attributes.dig('email', 'html_content', 'full')).to include('<strong>markdown</strong>')
          expect(message.content_attributes.dig('email', 'text_content', 'full')).to eq 'Regular **markdown** content'
        end
      end

      context 'when liquid templates are present in email content' do
        let(:contact) { create(:contact, name: 'John', email: 'john@example.com') }
        let(:conversation) { create(:conversation, inbox: channel_email.inbox, account: account, contact: contact) }

        it 'processes liquid variables in email content' do
          params = ActionController::Parameters.new({
                                                      content: 'Hello {{contact.name}}, your email is {{contact.email}}'
                                                    })

          message = described_class.new(user, conversation, params).perform

          expect(message.content_attributes.dig('email', 'html_content', 'full')).to include('Hello John')
          expect(message.content_attributes.dig('email', 'html_content', 'full')).to include('john@example.com')
          expect(message.content_attributes.dig('email', 'text_content', 'full')).to eq 'Hello John, your email is john@example.com'
        end

        it 'does not process liquid in code blocks' do
          params = ActionController::Parameters.new({
                                                      content: 'Hello {{contact.name}}, use this code: `{{contact.email}}`'
                                                    })

          message = described_class.new(user, conversation, params).perform

          expect(message.content_attributes.dig('email', 'text_content', 'full')).to eq 'Hello John, use this code: `{{contact.email}}`'
        end

        it 'handles broken liquid syntax gracefully' do
          params = ActionController::Parameters.new({
                                                      content: 'Hello {{contact.name}  {{invalid}}'
                                                    })

          message = described_class.new(user, conversation, params).perform

          expect(message.content_attributes.dig('email', 'text_content', 'full')).to eq 'Hello {{contact.name}  {{invalid}}'
        end

        it 'does not process liquid for incoming messages' do
          params = ActionController::Parameters.new({
                                                      content: 'Hello {{contact.name}}',
                                                      message_type: 'incoming'
                                                    })

          api_channel = create(:channel_api, account: account)
          api_conversation = create(:conversation, inbox: api_channel.inbox, account: account, contact: contact)

          message = described_class.new(user, api_conversation, params).perform

          expect(message.content).to eq 'Hello {{contact.name}}'
        end

        it 'does not process liquid for private messages' do
          params = ActionController::Parameters.new({
                                                      content: 'Hello {{contact.name}}',
                                                      private: true
                                                    })

          message = described_class.new(user, conversation, params).perform

          expect(message.content_attributes.dig('email', 'html_content')).to be_nil
          expect(message.content_attributes.dig('email', 'text_content')).to be_nil
        end
      end
    end
  end
end
