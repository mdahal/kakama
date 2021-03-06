class Notifier < ActionMailer::Base
  ActionMailer::Base.default_url_options[:host] = Setting.site_host
  ActionMailer::Base.default_content_type = "text/html"

  # Create a method that allows us to send emails if email exists,
  # otherwise send the PDF equivelent to the administrator for testing

  # If you need to add attachments, use the add_attachment(s) method
  # You also need to use part() {} to add a message body because you're
  # sending a multipart email. See postage_delivery_required as an example

  # Which email types should admins be CC'd on?
  CC_TO_ADMIN = %w{ email_to_all_staff event_rosterings_contact
                    postage_delivery_required staff_email }

  # An array of mailing templates that are static (don't contain information spefic to a staff member)
  # These are used to decide if an email gets sent in mass via bcc, or one at a time (via to)
  STATIC_MAILERS = %w{ email_to_all_staff event_rosterings_contact }

  # Overwrite ActionMailers default initialize method to store @mailer_name
  # which we can then access later on
  def initialize(*parameters) #:nodoc:
    @mailer_name = parameters.first
    super
  end

  # Provide a way to send emails to users with email addresses, or email the pdfs to admins if the
  # recipient doesn't have an email address. For people with emails, send one email with their email
  # in the bcc field if the email type is static, i.e. dont references them specifically
  def self.deliver_email_or_pdf_of(type, recipients, *args)
    recipients_with_emails, recipients_without_emails = Array.new, Array.new
    pdf_generators, event = Array.new, args.find { |arg| arg.is_a?(Event) }

    # Determine which recipients have emails to send to,
    # and which need PDFs printed and mailed to them
    Array(recipients).each do |recipient|
      if recipient.is_a?(Staff) && recipient.email.blank?
        recipients_without_emails << recipient
      else
        recipients_with_emails << recipient
      end
    end

    # If this email type is static, send all recipients to it for
    # bulk emailing, rather than sending emails one by one
    if recipients_with_emails.size > 0
      if STATIC_MAILERS.include?(type.to_s)
        Notifier.send("deliver_#{type.to_s}", recipients_with_emails, *args)
      else
        recipients_with_emails.each do |recipient|
          Notifier.send("deliver_#{type.to_s}", recipient, *args)
        end
      end
    end

    # For the rest without emails, send pdfs to the site admins for mailing
    if recipients_without_emails.size > 0
      recipients_without_emails.each do |recipient|
        generator = PdfGenerator.send("create_#{type.to_s}", recipient, *args)
        generator.filename = "#{type.to_s}_for_#{recipient.username}.pdf"
        pdf_generators << generator.save
      end
      Notifier.deliver_collection_of_pdfs(pdf_generators, event)
    end
  end

  def self.deliver_collection_of_pdfs(pdf_generators, *args)
    # incase admins get sent too many emails, provide an
    # option to limit attachment count in each email
    all_pdf_paths = pdf_generators.collect { |generator| generator.save_path }
    if Setting.attachment_limit && Setting.attachment_limit.to_i > 0
      all_pdf_paths.in_groups_of(Setting.attachment_limit.to_i, false).each do |pdf_paths|
        Notifier.deliver_postage_delivery_required(pdf_paths, *args)
      end
    else
      Notifier.deliver_postage_delivery_required(all_pdf_paths, *args)
    end

    pdf_generators.each { |generator| generator.delete! }
  end

  #
  # All mailer methods are sorted alphabetically according to the view file
  #

  def availability_changes_notification(recipient, availability)
    subject = if recipient.is_a?(Staff)
      'Your availability has been changed by an administrator'
    else
      "Availability of #{availability.staff.full_name} has been changed"
    end
    setup_email 'Availability Changes', subject, recipient
    body        :availability => availability
  end

  def email_to_all_staff(recipients, email_subject, email_body)
    setup_email 'Site Wide email', 'An administrator has sent all staff members an email',
                { :to => Setting.notifier_email_with_name, :bcc => recipients }
    body        :email_subject => email_subject, :email_body => email_body
  end

  def event_cancelled_notification(recipient, event, role)
    setup_email 'Event Cancelled', "The event '#{event.name}' has been cancelled", recipient, event
    body        :recipient => recipient, :event => event, :role => role
  end

  def event_name_change_notification(recipient, event, role, previous_name)
    setup_email 'Event Name Changed', "The event '#{previous_name}' has been renamed '#{event.name}'", recipient, event
    body        :recipient => recipient, :event => event, :role => role, :previous_name => previous_name
  end

  def event_rosterings_contact(recipients, event, email_subject, email_body)
    setup_email 'Event Rostering Contact', "An administrator has contacted you regarding the event '#{event.name}'",
                { :to => Setting.notifier_email_with_name, :bcc => recipients }, event
    body        :event => event, :email_subject => email_subject, :email_body => email_body
  end

  def event_time_change_notification(recipient, event, role, is_available)
    setup_email 'Event Time Changed', "The event '#{event.name}' has had it's start or end times changed", recipient, event
    body        :recipient => recipient, :event => event, :role => role, :is_available => is_available
  end

  # events_and_roles looks like this:   { Event => Role, Event => Role }
  def multiple_rostering_created_notification(recipient, events_and_roles)
    setup_email 'Multiple Events Rostered to Staff', 'You have been scheduled to work at multiple new events', recipient, events_and_roles.keys
    body        :recipient => recipient, :events_and_roles => events_and_roles
  end

  def password_reset_instructions(recipient)
    setup_email 'Password Reset Instructions', 'Instructions to reset your password', recipient
    body        :perishable_token => recipient.perishable_token
  end

  def postage_delivery_required(attachment_paths, event = nil)
    recipient = event ? (event.approved? ? event.approver : event.organiser) : nil
    recipient = Setting.site_administrator_emails if recipient.nil? || recipient.email.blank?
    setup_email 'Postage Notification Required', 'Document printing and mail to staff required', recipient
    add_attachments attachment_paths
    part :content_type => "text/html", :body => render_message("postage_delivery_required", {})
  end

  def rostering_cancelled_notification(recipient, event, role, reason='')
    setup_email 'Event Rostering Cancelled', "An administrator has cancelled your involvement at the event '#{event.name}'", recipient, event
    body        :recipient => recipient, :event => event, :role => role, :reason => reason
  end

  def rostering_confirmed_notification(recipient, event, role)
    setup_email 'Event Rostering Confirmed', "Confirmation of details for your new rostering at the event '#{event.name}'", recipient, event
    body        :recipient => recipient, :event => event, :role => role
  end

  def rostering_created_notification(recipient, event, role)
    setup_email 'Event Rostered to Staff', 'You have been scheduled to work at a new event', recipient, event
    body        :recipient => recipient, :event => event, :role => role
  end

  def staff_account_creation(recipient)
    setup_email 'Account Creation', 'An account has been created for you', recipient
    body        :recipient => recipient
  end

  def staff_email(recipient, email_subject, email_body)
    setup_email 'Personal Email', 'An administrator has sent you a personalized email', recipient
    body        :recipient => recipient, :email_subject => email_subject, :email_body => email_body
  end

  private

  def setup_email(email_type, subject_text, recipient, events=nil)
    subject      format_subject(subject_text)
    from         Setting.notifier_email_with_name
    reply_to     Setting.notifier_email_with_name

    # returns a hash containing strings of emails in :to, :cc, and :bcc keys
    recipient = parse_recipients(recipient)

    if recipient[:to].blank? && recipient[:cc].blank? && recipient[:bcc].blank?
      raise "ERROR: Trying to send email without any recipients. #{email_type} - #{subject_text}"
    end

    recipients recipient[:to] if recipient[:to].present?
    cc         recipient[:cc] if recipient[:cc].present?
    bcc        recipient[:bcc] if recipient[:bcc].present?

    # create an email log of what got sent and to whom for any staff instances
    # that were found during the parsing of to/cc/bcc data
    Array(@staff_instances).each do |contact|
      next unless contact.is_a?(Staff)

      details = {
        :email_type => email_type,
        :subject => subject_text,
        :staff => contact,
      }

      if events.is_a?(Array)
        events.each { |event| EmailLog.create!(details.merge(:event => event)) }
      else
        EmailLog.create!(details.merge(:event => events))
      end
    end
  end

  def format_subject(text)
    "#{Setting.site_name} - #{text}"
  end

  def parse_recipients(recipients)
    if recipients.is_a?(Hash)
      recipients.symbolize_keys!

      # Convert all values into an array to append to and loop over later
      [:to, :cc, :bcc].each do |type|
        value = recipients[type]
        recipients[type] = Array(value) unless value.is_a?(Array)
      end

      # Add site administrator to the email CC if enabled
      if Setting.administrators_get_special_emails && CC_TO_ADMIN.include?(@mailer_name)
        recipients[:cc] ||= Array.new
        recipients[:cc] += Setting.site_administrator_emails.uniq
      end

      # Format all recipients, and make sure the same email doesn't show up twice
      @contacted_emails = Array.new
      [:to, :cc, :bcc].each do |type|
        value = recipients[type]
        recipients[type] = value.collect do |v|
          email = format_recipient(v)
          email unless contacted_emails_includes?(email)
        end.compact
        @contacted_emails += recipients[type]
      end

      recipients
    else
      # Anything passed in other than a hash is considered a :to value
      parse_recipients({ :to => recipients })
    end
  end

  def contacted_emails_includes?(email)
    @contacted_emails.any? do |contacted|
      contacted =~ /#{Regexp.escape(email)}/ || email =~ /#{Regexp.escape(contacted)}/
    end
  end

  def format_recipient(recipient)
    if recipient.is_a?(Staff)
      @staff_instances ||= Array.new
      @staff_instances << recipient
      recipient.email_with_name
    else
      recipient
    end
  end

  def add_attachment(attachment_path)
    # If we send attachments, make sure we make this a mixed content type email
    content_type 'multipart/mixed'

    File.open(attachment_path) do |file|
      filename = File.basename(file.path)
      attachment :filename => filename, :content_type => File.mime_type?(file), :body => file.read
    end
  end

  def add_attachments(attachment_paths)
    Array(attachment_paths).each { |path| add_attachment(path) }
  end

end
