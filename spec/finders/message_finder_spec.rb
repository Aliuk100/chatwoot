require 'rails_helper'

describe MessageFinder do
  subject(:message_finder) { described_class.new(conversation, params) }

  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:contact) { create(:contact, email: nil) }
  let!(:conversation) do
    create(:conversation, account: account, inbox: inbox, assignee: user, contact: contact)
  end

  before do
    create(:message, account: account, inbox: inbox, conversation: conversation)
    create(:message, message_type: 'activity', account: account, inbox: inbox, conversation: conversation)
    create(:message, message_type: 'activity', account: account, inbox: inbox, conversation: conversation)
    # this outgoing message creates 2 additional messages because of the email hook execution service
    create(:message, message_type: 'outgoing', account: account, inbox: inbox, conversation: conversation)
  end

  describe '#perform' do
    context 'with filter_internal_messages false' do
      let(:params) { { filter_internal_messages: false } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 6
      end
    end

    context 'with filter_internal_messages true' do
      let(:params) { { filter_internal_messages: true } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 4
      end
    end

    context 'with before attribute' do
      let!(:outgoing) { create(:message, message_type: 'outgoing', account: account, inbox: inbox, conversation: conversation) }
      let(:params) { { before: outgoing.id } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 6
      end
    end

    context 'with a before attribute above the message id range' do
      let!(:max_id_message) do
        create(:message, id: described_class::MESSAGE_ID_MAX, account: account, inbox: inbox, conversation: conversation)
      end
      let(:params) { { before: 4_611_686_018_427_387_903 } }

      it 'includes the maximum valid message id without overflowing the database column' do
        expect(message_finder.perform).to include(max_id_message)
      end
    end

    context 'with after attribute' do
      let(:params) { { after: conversation.messages.first.id } }

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 5
        expect(result.first.id).to be conversation.messages.second.id
        expect(result.last.message_type).to eq 'outgoing'
      end
    end

    context 'with an after attribute above the message id range' do
      let(:params) { { after: 881_965_304_328 } }

      it 'returns no messages without overflowing the database column' do
        expect(message_finder.perform).to be_empty
      end
    end

    context 'with after and before attribute' do
      let(:params) do
        {
          after: conversation.messages.first.id,
          before: conversation.messages.last.id
        }
      end

      it 'filter conversations by status' do
        result = message_finder.perform
        expect(result.count).to be 5
        expect(result.last.id).to be conversation.messages[-2].id
      end
    end

    context 'with after and before attributes above the message id range' do
      let!(:max_id_message) do
        create(:message, id: described_class::MESSAGE_ID_MAX, account: account, inbox: inbox, conversation: conversation)
      end
      let(:params) do
        {
          after: 881_965_304_328,
          before: 4_611_686_018_427_387_903
        }
      end

      it 'returns no messages' do
        result = message_finder.perform

        expect(result).to be_empty
        expect(result).not_to include(max_id_message)
      end
    end

    context 'with reverse-inserted Messages360 historical messages' do
      let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }

      let!(:conversation) do
        create(
          :conversation,
          account: account,
          inbox: inbox,
          assignee: user,
          contact: contact,
          custom_attributes: { 'os360_channel' => 'ebay' }
        )
      end

      before do
        Message.where(conversation_id: conversation.id).delete_all
        25.times do |index|
          create(
            :message,
            account: account,
            inbox: inbox,
            conversation: conversation,
            source_id: "m360-msg-#{index}",
            created_at: Time.utc(2024, 1, 25) - index.days,
            content_attributes: {
              'messages360_channel' => 'ebay',
              'messages360_import_only' => true,
              'messages360_message_id' => index.to_s,
              'messages360_conversation_id' => 'provider-conversation'
            }
          )
        end
      end

      it 'returns the latest 20 messages in chronological order' do
        result = described_class.new(conversation, {}).perform

        expect(result.length).to eq(20)
        expect(result.map(&:created_at)).to eq(result.map(&:created_at).sort)
        expect(result.first.created_at).to eq(Time.utc(2024, 1, 6))
        expect(result.last.created_at).to eq(Time.utc(2024, 1, 25))
      end

      it 'returns all five earlier messages across the 20-message boundary' do
        latest_page = described_class.new(conversation, {}).perform
        earlier_page = described_class.new(conversation, { before: latest_page.first.id }).perform

        expect(earlier_page.length).to eq(5)
        expect(earlier_page.map(&:created_at)).to eq((1..5).map { |day| Time.utc(2024, 1, day) })
      end

      it 'paginates after by provider chronology rather than insertion ID' do
        cursor = conversation.messages.find_by!(created_at: Time.utc(2024, 1, 20))
        result = described_class.new(conversation, { after: cursor.id }).perform

        expect(result.map(&:created_at)).to eq((21..25).map { |day| Time.utc(2024, 1, day) })
      end

      it 'paginates between inclusive after and exclusive before cursors' do
        after_cursor = conversation.messages.find_by!(created_at: Time.utc(2024, 1, 10))
        before_cursor = conversation.messages.find_by!(created_at: Time.utc(2024, 1, 15))
        result = described_class.new(conversation, { after: after_cursor.id, before: before_cursor.id }).perform

        expect(result.map(&:created_at)).to eq((10..14).map { |day| Time.utc(2024, 1, day) })
      end

      it 'orders equal timestamps by ID across cursor boundaries' do
        cursor = conversation.messages.find_by!(created_at: Time.utc(2024, 1, 25))
        tied = create(:message, message_type: :incoming, conversation: conversation, account: account, inbox: inbox, created_at: cursor.created_at)

        expect(described_class.new(conversation, { after: cursor.id }).perform.map(&:id)).to eq([tied.id])
        expect(described_class.new(conversation, { before: tied.id }).perform.last.id).to eq(cursor.id)
        expect(described_class.new(conversation, { after: cursor.id, before: tied.id }).perform.map(&:id)).to eq([cursor.id])
      end

      it 'includes later live traffic in mixed chronological history' do
        live = create(:message, message_type: :incoming, conversation: conversation, account: account, inbox: inbox)
        latest = described_class.new(conversation, {}).perform

        expect(latest.last.id).to eq(live.id)
        expect(latest.map(&:created_at)).to eq(latest.map(&:created_at).sort)
      end

      it 'uses a filtered-out cursor timestamp without returning the private message' do
        cursor = conversation.messages.find_by!(created_at: Time.utc(2024, 1, 20))
        cursor.update!(private: true)
        result = described_class.new(conversation, { after: cursor.id, filter_internal_messages: true }).perform

        expect(result.map(&:created_at)).to eq((21..25).map { |day| Time.utc(2024, 1, day) })
      end

      it 'retains ID fallback for missing single cursors and returns empty for missing between bounds' do
        missing_id = conversation.messages.maximum(:id) + 100

        expect(described_class.new(conversation, { after: missing_id }).perform).to be_empty
        expect(described_class.new(conversation, { before: missing_id }).perform.length).to eq(20)
        expect(described_class.new(conversation, { after: missing_id, before: missing_id + 1 }).perform).to be_empty
        expect(described_class.new(conversation, { after: conversation.messages.first.id, before: missing_id }).perform).to be_empty
      end

      it 'keeps stock ID pagination for an ordinary eBay conversation without marked history' do
        conversation.messages.each { |message| message.update!(content_attributes: {}) }
        cursor = conversation.messages.find_by!(created_at: Time.utc(2024, 1, 20))
        result = described_class.new(conversation, { after: cursor.id }).perform

        expect(result.map(&:created_at)).to eq((1..19).map { |day| Time.utc(2024, 1, day) })
      end
    end
  end
end
