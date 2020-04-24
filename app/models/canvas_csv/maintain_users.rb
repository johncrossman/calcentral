module CanvasCsv
  # Updates users currently present within Canvas.
  # Used by CanvasCsv::RefreshCampusDataAll and CanvasCsv::RefreshCampusDataRecent to maintain officially enrolled students/faculty.
  # See CanvasCsv::AddNewUsers for maintenance of new active CalNet users within Canvas.
  class MaintainUsers < Base
    include ClassLogger
    attr_accessor :sis_user_id_changes, :user_email_deletions

    # Returns true if user hashes are identical
    def self.provisioned_account_eq_sis_account?(provisioned_account, sis_account)
      # Canvas interprets an empty 'email' column as 'Do not change.'
      matched = provisioned_account['login_id'] == sis_account['login_id'] &&
        (sis_account['email'].blank? || (provisioned_account['email'] == sis_account['email']))
      if matched && Settings.canvas_proxy.maintain_user_names
        # Canvas plays elaborate games with user name imports. See the RSpec for examples.
        matched = provisioned_account['full_name'] == "#{sis_account['first_name']} #{sis_account['last_name']}"
      end
      matched
    end

    # Updates SIS User ID for Canvas User
    #
    # Because there is no way to do a bulk download of user login objects, two Canvas requests are required to
    # set each user's SIS user ID.
    def self.change_sis_user_id(canvas_user_id, new_sis_user_id)
      logins_proxy = Canvas::Logins.new
      response = logins_proxy.user_logins(canvas_user_id)
      if (user_logins = response[:body])
        # We look for the login with a numeric "unique_id", and assume it is an LDAP UID.
        user_logins.select! do |login|
          parse_login_id(login['unique_id'])[:ldap_uid]
        end
        if user_logins.length > 1
          logger.error "Multiple numeric logins found for Canvas user #{canvas_user_id}; will skip"
        elsif user_logins.empty?
          logger.warn "No LDAP UID login found for Canvas user #{canvas_user_id}; will skip"
        else
          login_object_id = user_logins[0]['id']
          logger.debug "Changing SIS ID for user #{canvas_user_id} to #{new_sis_user_id}"
          response = logins_proxy.change_sis_user_id(login_object_id, new_sis_user_id)
          return true if response[:statusCode] == 200
        end
      end
      false
    end

    def self.parse_login_id(login_id)
      if (matched = /^(inactive-)?([0-9]+)$/.match login_id)
        inactive_account = matched[1]
        ldap_uid = matched[2].to_i
      end
      {
        ldap_uid: ldap_uid,
        inactive_account: inactive_account.present?
      }
    end

    def initialize(known_users, sis_user_import_csv, sis_ids_import_csv=nil, opts={})
      super()
      @known_users = known_users
      @known_sis_id_updates = {}
      @user_import_csv = sis_user_import_csv
      @sis_ids_import_csv = sis_ids_import_csv
      @cached = opts[:cached]
      @sis_user_id_changes = {}
      @user_email_deletions = []
    end

    def whitelisted_uids
      @whitelisted_uids ||= User::Auth.canvas_whitelist
    end

    # Appends account changes to the given CSV.
    # Appends all known user IDs to the input array.
    # Makes any necessary changes to SIS user IDs.
    def refresh_existing_user_accounts(uid_filter=nil)
      check_all_user_accounts(uid_filter)
      if Settings.canvas_proxy.import_zipped_csvs.present?
        change_sis_user_ids_by_csv
      else
        change_sis_user_ids_by_api
      end
      if Settings.canvas_proxy.delete_bad_emails.present?
        handle_email_deletions @user_email_deletions
      else
        logger.warn "EMAIL DELETION BLOCKED: Would delete email addresses for #{@user_email_deletions.length} inactive users: #{@user_email_deletions}"
      end
    end

    def check_all_user_accounts(uid_filter)
      if @cached
        # If we've been asked to use a cached file, grab the most recent stashed users CSV we have on disk. Also, grab any CSV updates we've
        # generated in the meantime and note the UIDs, so we don't attempt to redo whatever user changes were already made.
        users_csv_file = Dir.glob("#{@export_dir}/provisioned-users-*.csv").sort.last
        logger.debug "Loading cached user report from #{users_csv_file}"
        timestamp_string = timestamp_from_filepath(users_csv_file)
        Dir.glob("#{@export_dir}/canvas*-users-*.csv").sort.each do |user_update_csv|
          logger.debug "Loading user update CSV from #{user_update_csv}"
          if timestamp_from_filepath(user_update_csv) > timestamp_string
            CSV.foreach(user_update_csv, headers: true) do |row|
              @known_users[row['login_id'].to_s] = row['user_id'].to_s
            end
          end
        end
        Dir.glob("#{@export_dir}/canvas*-sis-ids.csv").sort.each do |sis_id_update_csv|
          logger.debug "Loading SIS id update CSV from #{sis_id_update_csv}"
          if timestamp_from_filepath(sis_id_update_csv) > timestamp_string
            CSV.foreach(sis_id_update_csv, headers: true) do |row|
              @known_sis_id_updates[row['old_id'].to_s] = row['new_id'].to_s
            end
          end
        end
      else
        users_csv_file = "#{@export_dir}/provisioned-users-#{DateTime.now.strftime('%F-%H-%M')}.csv"
        users_csv_file = Canvas::Report::Users.new(download_to_file: users_csv_file).get_csv
      end
      if users_csv_file.present?
        accounts_batch = []
        CSV.foreach(users_csv_file, headers: true) do |account_row|
          if !uid_filter || uid_filter.include?(sanitize_login_id account_row['login_id'])
            accounts_batch << account_row
          end
          if accounts_batch.length == 1000
            compare_to_campus(accounts_batch)
            accounts_batch = []
          end
        end
        compare_to_campus(accounts_batch) if accounts_batch.present?
      end
    end

    # Any changes to SIS user IDs must take effect before the enrollments CSV is generated.
    # Otherwise, the generated CSV may include a new ID that does not match the existing ID for a user account.
    def change_sis_user_ids_by_api
      if Settings.canvas_proxy.dry_run_import.present?
        logger.warn "DRY RUN MODE: Would change #{@sis_user_id_changes.length} SIS user IDs #{@sis_user_id_changes.inspect}"
      else
        logger.warn "About to change #{@sis_user_id_changes.length} SIS user IDs"
        @sis_user_id_changes.each do |canvas_user_id, change|
          new_sis_id = change['new_id']
          succeeded = self.class.change_sis_user_id(canvas_user_id, new_sis_id)
          unless succeeded
            # If we had ideal data sources, it would be prudent to remove any mention of the no-longer-going-to-be-changed
            # SIS User ID from the import CSVs. However, the failure was likely triggered by Canvas's inconsistent
            # handling of deleted records, with a deleted user login being completely invisible and yet still capable
            # of blocking new records. The only way to make the deleted record available for inspection and clean-up is
            # to go on with the import.
            logger.error "Canvas user #{canvas_user_id} did not successfully have its SIS ID changed to #{new_sis_id}! Check for duplicated LDAP UIDs in bCourses."
          end
        end
      end
    end

    def change_sis_user_ids_by_csv
      if !@sis_ids_import_csv
        logger.error 'No Import CSV file provided to handle SIS ID changes - no changes will be made!'
      else
        logger.warn "About to add #{@sis_user_id_changes.length} SIS user ID changes to CSV"
        @sis_user_id_changes.values.each do |change|
          change_row = change.merge(
            'integration_id' => nil,
            'new_integration_id' => nil,
            'type' => 'user'
          )
          @sis_ids_import_csv << change_row
        end
      end
    end

    # Instructure interprets a blank 'email' value in an import CSV as 'Leave the existing email alone.'
    # This time-consuming API approach seems to be the only way to remove obsolete email addresses.
    # Also, 'Users can delete their institution-assigned email address' must be enabled in Canvas
    # settings before attempting to delete communication channels.
    def handle_email_deletions(canvas_user_ids)
      logger.warn "About to delete email addresses for #{canvas_user_ids.length} inactive users: #{canvas_user_ids}"
      canvas_user_ids.each do |canvas_user_id|
        proxy = Canvas::CommunicationChannels.new(canvas_user_id: canvas_user_id)
        if (channels = proxy.list[:body])
          channels.each do |channel|
            if channel['type'] == 'email'
              channel_id = channel['id']
              dry_run = Settings.canvas_proxy.dry_run_import
              if dry_run.present?
                logger.warn "DRY RUN MODE: Would delete communication channel #{channel}"
              else
                logger.warn "Deleting communication channel #{channel}"
                proxy.delete channel_id
              end
            end
          end
        end
      end
    end

    def categorize_user_account(existing_account, campus_user_attributes)
      # Convert from CSV::Row for easier manipulation.
      old_account_data = existing_account.to_hash
      new_account_data = old_account_data
      parsed_login_id = self.class.parse_login_id old_account_data['login_id']
      ldap_uid = parsed_login_id[:ldap_uid]
      inactive_account = parsed_login_id[:inactive_account]
      whitelisted = whitelisted_uids.include?(ldap_uid.to_s)
      if ldap_uid
        if @known_users[ldap_uid.to_s].present?
          logger.debug "User account for UID #{ldap_uid} already processed, will not attempt to re-process."
          return
        end
        campus_user = campus_user_attributes.select { |r| (r[:ldap_uid].to_i == ldap_uid) }.first
        if campus_user.present? && (!campus_user[:roles][:expiredAccount] || whitelisted)
          logger.warn "Reactivating account for LDAP UID #{ldap_uid}" if inactive_account
          new_account_data = canvas_user_from_campus_attributes campus_user
        elsif whitelisted
          if inactive_account
            logger.warn "Reactivating account for unknown LDAP UID #{ldap_uid}"
            new_account_data = old_account_data.merge('login_id' => ldap_uid)
          end
        else
          # Check to see if there are obsolete email addresses to (potentially) delete.
          if old_account_data['email'].present? &&
            (inactive_account || Settings.canvas_proxy.inactivate_expired_users)
            @user_email_deletions << old_account_data['canvas_user_id']
          end
          if Settings.canvas_proxy.inactivate_expired_users
            # This LDAP UID no longer appears in campus data. Mark the Canvas user account as inactive.
            logger.warn "Inactivating account for LDAP UID #{ldap_uid}" unless inactive_account
            new_account_data = old_account_data.merge(
              'login_id' => "inactive-#{ldap_uid}",
              'user_id' => "UID:#{ldap_uid}",
              'email' => nil
            )
          end
        end
        if old_account_data['user_id'] != new_account_data['user_id']
          if @known_sis_id_updates[old_account_data['user_id']].present?
            logger.debug "SIS ID change from #{old_account_data['user_id']} to #{new_account_data['user_id']} already processed, will not attempt to re-process."
          else
            logger.warn "Will change SIS ID for user sis_login_id:#{old_account_data['login_id']} from #{old_account_data['user_id']} to #{new_account_data['user_id']}"
            @sis_user_id_changes["sis_login_id:#{old_account_data['login_id']}"] = {
              'old_id' => old_account_data['user_id'],
              'new_id' => new_account_data['user_id']
            }
          end
        end
        @known_users[ldap_uid.to_s] = new_account_data['user_id']
        unless self.class.provisioned_account_eq_sis_account?(old_account_data, new_account_data)
          @user_import_csv << new_account_data
        end
      end
    end

    def compare_to_campus(accounts_batch)
      campus_user_rows = User::BasicAttributes.attributes_for_uids(accounts_batch.collect { |r| sanitize_login_id r['login_id'] })
      accounts_batch.each do |existing_account|
        categorize_user_account(existing_account, campus_user_rows)
      end
    end

    def sanitize_login_id(login_id)
      login_id.to_s.gsub(/^inactive-/, '')
    end

  end
end
