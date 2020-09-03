class ApplicationController < ActionController::Base
  include Pundit
  protect_from_forgery
  before_action :check_reauthentication
  before_action :deny_if_filtered
  before_action :set_access_control_headers
  after_action :access_log
  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  def authenticate(force = false)
    redirect_to url_for_path('/auth/cas') unless !force && session['user_id']
  end

  # TODO see if we can standardize empty responses. We have 2 forms: This one, which returns empty JSON and
  # an HTTP 200 status, and another form that returns empty body with 401 status.
  def api_authenticate
    if session['user_id'].blank?
      Rails.logger.warn "Authenticated user absent in request to #{controller_name}\##{action_name}"
      render :json => {}.to_json
    end
  end

  def api_authenticate_401
    if session['user_id'].blank?
      Rails.logger.warn "Authenticated user absent in request to #{controller_name}\##{action_name}"
      head 401
    end
  end

  def reauthenticate(opts = {})
    delete_reauth_cookie
    url = '/auth/cas?renew=true'
    url << "&url=#{url_for_path opts[:redirect_path]}" if opts[:redirect_path]
    redirect_to url_for_path url
  end

  def check_reauthentication
    unless !!session['user_id']
      delete_reauth_cookie
      return
    end
    reauthenticate(redirect_path: '/') if session_state_requires_reauthentication?
  end

  def allow_if_classic_view_as?
    true
  end
  def allow_if_canvas_lti?
    false
  end
  def deny_if_filtered
    if !allow_if_classic_view_as? && current_user.classic_viewing_as?
      raise Pundit::NotAuthorizedError.new("By View As user #{current_user.original_user_id}")
    elsif !allow_if_canvas_lti? && current_user.lti_authenticated_only
      raise Pundit::NotAuthorizedError.new('In LTI session')
    end
  end

  def delete_reauth_cookie
    cookies.delete :reauthenticated
  end

  def current_user
    @current_user ||= AuthenticationState.new(session)
  end

  def expire_current_user
    Cache::UserCacheExpiry.notify current_user.real_user_id
  end

  # override of Rails default behavior:
  # reset session AND return 401 when CSRF token validation fails
  def handle_unverified_request
    reset_session
    head 401
  end

  # Rails url_for defaults the protocol to "request.protocol". But if SSL is being
  # provided by Apache or Nginx, the reported protocol will be "http://". To fix
  # callback URLs, we need to override.
  def default_url_options
    if defined?(Settings.application.protocol) && !Settings.application.protocol.blank?
      Rails.logger.debug("Setting default URL protocol to #{Settings.application.protocol}")
      {protocol: Settings.application.protocol}
    else
      {}
    end
  end

  def check_directly_authenticated
    unless current_user.directly_authenticated?
      raise Pundit::NotAuthorizedError.new("By View-As user #{current_user.real_user_id}")
    end
  end

  def check_google_access
    authorize current_user, :access_google?
  end

  def user_not_authorized(error)
    Rails.logger.warn "Unauthorized request made by UID: #{session['user_id']} to #{controller_name}\##{action_name}: #{error.message}"
    render_403 error
  end

  def fetch_another_users_attributes(uid)
    User::SearchUsersByUid.new(user_search_constraints.merge id: uid).search_users_by_uid
  end

  # Set limits on who can reach personal data of another user.
  def user_search_constraints
    if current_user.policy.can_view_as?
      if current_user.policy.can_view_confidential?
        {except: []}
      else
        {except: [:confidential]}
      end
    else
      raise Pundit::NotAuthorizedError.new("User (UID: #{uid}) is not allowed to View As")
    end
  end

  def render_403(error)
    # Subclasses might render JSON including error message.
    head 403
  end

  def handle_api_exception(error)
    Rails.logger.error "#{error.class} raised with UID: #{session['user_id']} in #{controller_name}\##{action_name}: #{error.message}"
    render json: { :error => error.message }.to_json, status: 500
  end

  def handle_exception(error)
    Rails.logger.error "#{error.class} raised with UID: #{session['user_id']} in #{controller_name}\##{action_name}: #{error.message}"
    render plain: error.message, status: 500
  end

  def handle_client_error(error)
    if error.is_a? Errors::BadRequestError
      Rails.logger.debug "Bad request made to #{controller_name}\##{action_name}: #{error.message}"
      render json: {:error => error.message}.to_json, status: 400 and return
    else
      Rails.logger.error "Unknown Error::ClientError handled in #{controller_name}\##{action_name}: #{error.class} - #{error.message}"
      render json: {:error => error.message}.to_json, status: 500 and return
    end
  end

  def self.correct_port(host_with_port, http_referer)
    # A developer on localhost running a local front-end server will expect port 3001. However, low-level Rails logic will deduce
    # a port value of 3000. Problems arise when we HTTP redirect: developer unexpectedly hops from 3001 to 3000.
    # Therefore, we use a conservative hack to undo the false assumption of Rails.
    if http_referer.to_s.include?('localhost:3001')
      host_with_port.sub(':3000', ':3001')
    else
      host_with_port
    end
  end

  def set_access_control_headers
    if Settings.features.vue_js && Settings.vue.localhost_base_url
      logger.warn "Settings.vue.localhost_base_url: #{Settings.vue.localhost_base_url}"
      headers['Access-Control-Allow-Headers'] = 'Content-Type'
      headers['Access-Control-Allow-Origin'] = Settings.vue.localhost_base_url
      headers['Access-Control-Allow-Credentials'] = 'true'
      headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS, PUT, DELETE'
    end
  end

  private

  def get_active_view_as_session_type
    SessionKey::VIEW_AS_TYPES.find { |key| session.has_key? key }
  end

  def get_original_viewer_uid
    key = get_active_view_as_session_type
    key && session[key]
  end

  def session_state_requires_reauthentication?
    Settings.features.reauthentication &&
      (current_user.classic_viewing_as?) &&
      !cookies[:reauthenticated]
  end

  def get_settings
    @server_settings = ServerRuntime.get_settings
  end

  def initialize_calcentral_config
    @uid = session['user_id'] ? session['user_id'].to_s : ''
    @calcentral_config ||= {
      applicationLayer: Settings.application.layer,
      applicationVersion: ServerRuntime.get_settings['versions']['application'],
      clientHostname: ServerRuntime.get_settings['hostname'],
      googleAnalyticsId: Settings.google_analytics_id,
      providedServices: Settings.application.provided_services,
      sentryUrl: Settings.sentry_url,
      uid: @uid
    }
  end

  def session_message
    SessionKey::ALL_KEYS.map { |key| "#{key}: #{session[key]}" if session[key] }.compact.join('; ')
  end

  def access_log
    # HTTP_X_FORWARDED_FOR is the client's IP when we're behind Apache; REMOTE_ADDR otherwise
    remote = request.env['HTTP_X_FORWARDED_FOR'] || request.env['REMOTE_ADDR']
    line = "ACCESS_LOG #{remote} #{request.request_method} #{request.filtered_path} #{status}"
    if (key = get_active_view_as_session_type)
      line += " #{key}=#{session[key]} is viewing uid=#{session['user_id']}"
    else
      line += " uid=#{session['user_id']}"
    end
    line += " class=#{self.class.name} action=#{params["action"]} view=#{view_runtime}ms db=#{db_runtime}ms"
    logger.warn line
  end

  # When given a relative path string as its first argument, Rails's redirect_to method ignores
  # the protocol setting in default_url_options, and instead fills in the URL protocol from the
  # request referer. Behind nginx or Apache, this causes a double redirect in the browser,
  # first to "http:" and then to "https:". This method makes relative paths safer to use.
  def url_for_path(path)
    if (protocol = default_url_options[:protocol])
      protocol + ApplicationController.correct_port(request.host_with_port, request.env['HTTP_REFERER']) + path
    else
      Settings.vue.localhost_base_url ? "#{Settings.vue.localhost_base_url}#{path}" : path
    end
  end

  def disable_xframe_options
    use_secure_headers_override(:disable_xframe_options)
  end

end
