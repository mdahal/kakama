class EventsController < ApplicationController
  before_filter :login_required
  before_filter :admin_required, :except => [:show]
  before_filter :redirect_staff_unless_event_approved, :only => [:show, :destroy]
  before_filter :redirect_staff_unless_event_editable, :only => [:edit, :update, :roster_staff, :alter_rosterings]

  def index
    @current_events = Event.approved.current.paginate :page => params[:page] if params[:type].blank?
    @upcoming_events = Event.approved.future.paginate :page => params[:page] if params[:type].blank?
    @past_events = Event.finished.paginate :page => params[:page] if params[:type] == 'past'
    @working_events = Event.working.current_or_future.paginate :page => params[:page] if params[:type] == 'working'
    @cancelled_events = Event.with_exclusive_scope { Event.not_deleted.cancelled.paginate :page => params[:page] } if params[:type] == 'cancelled'
  end

  def show
    # event is fetched in a before filter
  end

  def new
    @event = Event.new(:venue_id => params[:venue_id])
  end

  def edit
    @event = Event.find(params[:id])
  end

  def create
    @event = Event.new(params[:event])
    @event.organiser_id = current_staff.id

    if @event.save
      flash[:notice] = 'Event was successfully created.'
      redirect_to(@event)
    else
      render :action => "new"
    end
  end

  def update
    @event = Event.find(params[:id])
    @event.approver_id = current_staff.id if params[:event][:state] && params[:event][:state] == 'approved'

    if @event.update_attributes(params[:event])
      flash[:notice] = 'Event was successfully updated.'
      redirect_to(@event)
    else
      render :action => "edit"
    end
  end

  def destroy
    # event is fetched in a before filter
    if request.delete?
      if Event.with_exclusive_scope { @event.destroy }
        flash[:notice] = "Event was successfully destroyed."
      else
        flash[:error] = @event.errors['base']
      end
      redirect_to(events_url)
    end
  end

  def cancel
    @event = Event.find(params[:id])
    if request.delete?
      if @event.cancel
        flash[:notice] = "Event was successfully cancelled. All involved will be notified."
      else
        flash[:error] = @event.errors['base']
      end
      redirect_to(events_url)
    end
  end

  def contact_staff
    @event = Event.find(params[:id])
    if request.post?
      if @event.contact_staff_rostered(params)
        flash[:notice] = "Emails have been sent to all those in the group you selected."
        redirect_to @event
      else
        flash[:error] = "Please select a group, and enter a subject and email body."
      end
    end
  end

  # Mass approving is a special case. Normally we send emails to staff when an event is approved
  # In the case of mass approving, we don't want to flood them with emails. So we turn off the
  # normal notification emails, and collect the staff, their events, and roles, then send one
  # email to them with all details of each approved event they're rostered to.
  # The Notifier.deliver_email_or_pdf_of  method also does not suit our needs here, so we
  # end up duplicating some of the PDF generation logic :-(
  def mass_approve
    events_past_cut_off, staff_event_mappings = Array.new, Hash.new

    Array(params[:approve_event_ids]).each do |event_id|
      event = Event.find_by_id(event_id.to_i)
      next unless event

      event.approver_id = current_staff.id
      event.skip_notification_email = true
      event.approved! if event.working?

      if event.passed_cut_off_date?
        events_past_cut_off << event
      else
        event.rosterings.unconfirmed.each do |rostering|
          staff_event_mappings[rostering.staff] ||= Hash.new
          staff_event_mappings[rostering.staff][event] = rostering.role
        end
      end
    end

    pdf_generators = Array.new
    # staff_event_mappings => { Staff => { Event => Role, Event => Role } }
    staff_event_mappings.each do |staff, events_and_roles|
      if staff.email.present?
        Notifier.deliver_multiple_rostering_created_notification(staff, events_and_roles)
      else
        generator = PdfGenerator.create_multiple_rostering_created_notification(staff, events_and_roles)
        generator.filename = "multiple_rostering_created_notification_for_#{staff.username}.pdf"
        pdf_generators << generator.save
      end
    end
    Notifier.deliver_collection_of_pdfs(pdf_generators) if pdf_generators.size > 0

    flash[:notice] = "All selected events have now been approved and all involved notified of the event."
    if events_past_cut_off.size > 0
      flash[:error] = render_to_string :partial => 'mass_approved_msg', :locals => { :events => events_past_cut_off }
    end
    redirect_to events_url
  end

  private

  def redirect_staff_unless_event_approved
    # By default, Event.find will exclude cancelled and deleted
    # events but we may want to see it in this case, so we use
    # with_exclusive_scope to get around the default_scope
    @event = Event.with_exclusive_scope { Event.find(params[:id]) }

    unless admin? || @event.approved?
      flash[:error] = "You cannot access the event at this time. Please try again later."
      redirect_to(dashboard_path)
    end
  end

  def redirect_staff_unless_event_editable
    @event ||= Event.find(params[:id])
    unless @event.editable?
      flash[:error] = "You cannot edit/change the event because it has started or was cancelled."
      redirect_to(events_url)
    end
  end
end
