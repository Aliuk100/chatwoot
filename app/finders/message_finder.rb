class MessageFinder
  MESSAGE_ID_MAX = 2_147_483_647

  def initialize(conversation, params)
    @conversation = conversation
    @params = params
  end

  def perform
    current_messages
  end

  private

  def conversation_messages
    @conversation.messages.includes(:attachments, :sender, sender: { avatar_attachment: [:blob] })
  end

  def messages
    return conversation_messages if @params[:filter_internal_messages].blank?

    conversation_messages.where.not('private = ? OR message_type = ?', true, 2)
  end

  def current_messages
    return messages.none if oversized_message_id?(@params[:after])

    if @params[:after].present? && @params[:before].present?
      messages_between(normalized_message_id(@params[:after]), @params[:before].to_i)
    elsif @params[:before].present?
      messages_before(@params[:before].to_i)
    elsif @params[:after].present?
      messages_after(normalized_message_id(@params[:after]))
    else
      messages_latest
    end
  end

  def messages_after(after_id)
    return messages_after_chronologically(after_id) if messages360_historical_conversation?

    messages.reorder('created_at asc').where('id > ?', after_id).limit(100)
  end

  def messages_before(before_id)
    return messages_latest if oversized_message_id?(before_id)

    before_id = normalized_message_id(before_id)
    return messages_before_chronologically(before_id) if messages360_historical_conversation?

    messages.reorder('created_at desc').where('id < ?', before_id).limit(20).reverse
  end

  def messages_between(after_id, before_id)
    return messages_between_chronologically(after_id, before_id) if messages360_historical_conversation?

    message_scope = messages.reorder('created_at asc').where('id >= ?', after_id)
    message_scope = message_scope.where('id < ?', normalized_message_id(before_id)) unless oversized_message_id?(before_id)
    message_scope.limit(1000)
  end

  def messages_latest
    order = messages360_historical_conversation? ? { created_at: :desc, id: :desc } : { created_at: :desc }
    messages.reorder(order).limit(20).reverse
  end

  def messages_after_chronologically(after_id)
    cursor = @conversation.messages.find_by(id: after_id)
    return messages.reorder('created_at asc').where('id > ?', after_id).limit(100) unless cursor

    messages.reorder(created_at: :asc, id: :asc)
            .where('messages.created_at > :created_at OR (messages.created_at = :created_at AND messages.id > :id)',
                   created_at: cursor.created_at, id: cursor.id)
            .limit(100)
  end

  def messages_before_chronologically(before_id)
    cursor = @conversation.messages.find_by(id: before_id)
    return messages.reorder('created_at desc').where('id < ?', before_id).limit(20).reverse unless cursor

    messages.reorder(created_at: :desc, id: :desc)
            .where('messages.created_at < :created_at OR (messages.created_at = :created_at AND messages.id < :id)',
                   created_at: cursor.created_at, id: cursor.id)
            .limit(20)
            .reverse
  end

  def messages_between_chronologically(after_id, before_id)
    after_cursor = @conversation.messages.find_by(id: after_id)
    before_cursor = @conversation.messages.find_by(id: before_id) unless oversized_message_id?(before_id)
    return messages.none unless after_cursor
    return messages.none unless oversized_message_id?(before_id) || before_cursor

    message_scope = messages.reorder(created_at: :asc, id: :asc)
                            .where('messages.created_at > :created_at OR (messages.created_at = :created_at AND messages.id >= :id)',
                                   created_at: after_cursor.created_at, id: after_cursor.id)
    if before_cursor
      message_scope = message_scope.where('messages.created_at < :created_at OR (messages.created_at = :created_at AND messages.id < :id)',
                                          created_at: before_cursor.created_at, id: before_cursor.id)
    end
    message_scope.limit(1000)
  end

  def messages360_historical_conversation?
    @conversation.messages.messages360_historical.exists?
  end

  def normalized_message_id(value)
    value.to_i.clamp(0, MESSAGE_ID_MAX)
  end

  def oversized_message_id?(value)
    value.to_i > MESSAGE_ID_MAX
  end
end

MessageFinder.prepend_mod_with('MessageFinder')
