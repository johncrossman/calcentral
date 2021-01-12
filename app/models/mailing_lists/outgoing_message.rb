require 'mail'

module MailingLists
  class OutgoingMessage
    include ClassLogger

    def initialize(mailing_list, member, opts={})
      @mailing_list = mailing_list
      @member = member
      @opts = opts
    end

    def send_message
      payload = {
        'subject' => @opts[:subject],
        'h:Reply-To' => @opts[:from],
        'html' => @opts[:body][:html],
        'text' => @opts[:body][:plain]
      }

      payload['Message-Id'] = @opts[:id] if @opts[:id]
      payload['text'] = ' ' if payload['html'].blank? && payload['text'].blank?

      set_attachments payload
      set_from payload

      # Mailgun limits batch sending to 1000 members at a time.
      response = nil
      @mailing_list.active_members.each_slice(1000) do |members|
        recipient_fields = self.class.get_recipient_fields members
        response = Mailgun::SendMessage.new.post payload.merge(recipient_fields)
        break unless response.try(:[], :response).try(:[], :sending)
      end
      response
    end

    # The empty hashes under 'recipient-variables' tell Mailgun not to include all member addresses in the 'To:' field.
    # See https://documentation.mailgun.com/user_manual.html#batch-sending
    def self.get_recipient_fields(members)
      to = []
      recipient_variables = {}
      members.each do |member|
        to << member.email_address
        recipient_variables[member.email_address] = {}
      end
      {
        'to' => to,
        'recipient-variables' => recipient_variables.to_json
      }
    end

    private

    def set_attachments(payload)
      return unless @opts[:attachments][:data]

      if @opts[:attachments][:cid_map]
        payload['inline'] = @opts[:attachments][:cid_map].map do |cid, key|
          if (attachment_data = @opts[:attachments][:data].delete key)
            if attachment_data.original_filename
              # Mailgun expects inline attachments to be specified by filename, not content-id.
              %w(html plain).each { |key| payload[key].try :gsub!, cid, attachment_data.original_filename }
            end
            to_upload_io attachment_data
          end
        end
      end

      if @opts[:attachments][:data].any?
        payload['attachment'] = @opts[:attachments][:data].map { |key, attachment_data| to_upload_io attachment_data }
      end
    end

    # To keep spam filters happy, the 'From:' address must have the same domain as the mailing list. However, we
    # can set the display name to match the original sender.
    def set_from(payload)
      address = Mail::Address.new
      address.address = ['no-reply', @mailing_list.class.domain].join '@'
      address.display_name = [@member.first_name, @member.last_name].join ' '
      address.display_name << " (#{@mailing_list.canvas_site_name})" if @mailing_list.canvas_site_name
      payload['from'] = address.to_s
    end

    def to_upload_io(attachment)
      tempfile = attachment.tempfile || ''
      type = attachment.content_type || 'application/octet-stream'
      filename = attachment.original_filename || ''
      Faraday::UploadIO.new(tempfile, type, filename)
    rescue => e
      logger.error "Could not create UploadIO instance from attachment data #{attachment}: #{e.class}: #{e.message}\n #{e.backtrace.join("\n ")}"
      nil
    end

  end
end
