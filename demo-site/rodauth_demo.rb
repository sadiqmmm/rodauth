require 'roda'
require 'sequel/core'
require 'mail'
require 'securerandom'

module RodauthDemo
class App < Roda
  if url = ENV.delete('RODAUTH_DATABASE_URL') || ENV.delete('DATABASE_URL')
    DB = Sequel.connect(url)
  else
    DB = Sequel.sqlite
    Sequel.extension :migration
    Sequel::Migrator.run(DB, File.expand_path('../../spec/migrate_travis', __FILE__))
  end
  DB.extension :date_arithmetic
  DB.freeze

  ::Mail.defaults do
    delivery_method :test
  end

  opts[:root] = File.dirname(__FILE__)

  MAILS = {}
  SMS = {}
  MUTEX = Mutex.new

  plugin :render, :escape=>true
  plugin :request_aref, :raise
  plugin :hooks
  plugin :flash
  plugin :common_logger
  plugin :route_csrf, :csrf_failure=>:clear_session

  secret = ENV.delete('RODAUTH_SESSION_SECRET') || SecureRandom.random_bytes(64)
  plugin :sessions, :secret=>secret, :key=>'rodauth-demo.session'

  plugin :rodauth, :json=>true, :csrf=>:route_csrf do
    db DB
    enable :change_login, :change_password, :close_account, :create_account,
           :lockout, :login, :logout, :remember, :reset_password, :verify_account,
           :otp, :recovery_codes, :sms_codes, :disallow_common_passwords,
           :disallow_password_reuse, :password_grace_period, :single_session, :jwt,
           :verify_login_change, :change_password_notify,
           :email_auth
    enable :webauthn if ENV["RODAUTH_WEBAUTHN"]
    max_invalid_logins 2
    account_password_hash_column :ph
    title_instance_variable :@page_title
    only_json? false
    login_input_type 'email'
    jwt_secret(secret)
    hmac_secret secret
    sms_send do |phone_number, message|
      MUTEX.synchronize{SMS[session_value] = "Would have sent the following SMS to #{phone_number}: #{message}"}
    end
  end

  plugin :error_handler do |_|
    @page_title = "Internal Server Error"
    view :content=>""
  end

  plugin :not_found do
    @page_title = "File Not Found"
    view :content=>""
  end

  def last_sms_sent
    MUTEX.synchronize{SMS.delete(rodauth.session_value)}
  end

  def last_mail_sent
    MUTEX.synchronize{MAILS.delete(rodauth.session_value)}
  end

  after do
    Mail::TestMailer.deliveries.each do |mail|
      MUTEX.synchronize{MAILS[rodauth.session_value] = mail}
    end
    Mail::TestMailer.deliveries.clear
  end

  route do |r|
    check_csrf! unless r.env['CONTENT_TYPE'] =~ /application\/json/
    rodauth.load_memory
    if session['single_session_check']
      rodauth.check_single_session
    end
    r.rodauth

    r.root do
      view 'index'
    end

    r.post "single-session" do
      session['single_session_check'] = !r['d']
      r.redirect '/'
    end
  end
  
  freeze
end
end
