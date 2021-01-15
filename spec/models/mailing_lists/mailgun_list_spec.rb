def csv_row_count(list)
  CSV.parse(list.members_welcomed_csv).count - 1
end

describe MailingLists::MailgunList do
  let(:canvas_site_id) { '1121' }
  let(:fake_course_data) { Canvas::Course.new(canvas_course_id: canvas_site_id, fake: true).course[:body] }
  before { allow_any_instance_of(Canvas::Course).to receive(:course).and_return(statusCode: 200, body: fake_course_data) }

  let(:response) { JSON.parse list.to_json}
  let(:list_domain) { Settings.mailgun_proxy.domain }

  include_examples 'a newly initialized mailing list'

  context 'creating a list' do
    let(:create_list) { described_class.create(canvas_site_id: canvas_site_id) }
    let(:list) { create_list }

    it 'reports list created' do
      count = described_class.count
      create_list
      expect(described_class.count).to eq count+1
      expect(response['mailingList']['state']).to eq 'created'
    end

    include_examples 'mailing list creation errors'
  end

  context 'an existing list record' do
    let(:list) { described_class.find_by(canvas_site_id: canvas_site_id) }
    let(:welcome_email_active) { true }
    let(:welcome_email_body) { '<p><b>Lasciate ogni speranza</b>, voi ch\'entrate!</p><p>Thanks, your pedagogue</p>' }
    let(:expected_welcome_email_text) { "Lasciate ogni speranza, voi ch\'entrate!\n\nThanks, your pedagogue\n\n" }
    let(:welcome_email_subject) { 'Welcome to the jungle' }

    before do
      described_class.create(canvas_site_id: canvas_site_id)  
      list.update(
        welcome_email_active: welcome_email_active,
        welcome_email_body: welcome_email_body,
        welcome_email_subject: welcome_email_subject
      ) 
    end

    it 'reports state as created' do
      expect(response['mailingList']['state']).to eq 'created'
      expect(response['mailingList']['creationUrl']).not_to be_present
      expect(response['mailingList']).not_to include('timeLastPopulated')
    end

    context 'populating list' do
      let(:course_users) { Canvas::CourseUsers.new(canvas_course_id: canvas_site_id, fake: true) }

      let(:oliver) do {
        'login_id' => '12345',
        'first_name' => 'Oliver',
        'last_name' => 'Heyer',
        'email' => 'oheyer@classics.berkeley.edu',
        'bmail' => 'oheyer@berkeley.edu',
        'enrollments' => [{
          'enrollment_state' => 'active',
          'role' => 'TeacherEnrollment'
        }]
      } end
      let(:ray) do {
        'login_id' => '67890',
        'first_name' => 'Ray',
        'last_name' => 'Davis',
        'email' => 'raydavis@cogsci.berkeley.edu',
        'bmail' => 'raydavis@berkeley.edu',
        'enrollments' => [{
          'enrollment_state' => 'active',
          'role' => 'StudentEnrollment'
        }]
      } end
      let(:paul) do {
        'login_id' => '65536',
        'first_name' => 'Paul',
        'last_name' => 'Kerschen',
        'email' => 'kerschen@english.berkeley.edu',
        'bmail' => 'kerschen@berkeley.edu',
        'enrollments' => [{
          'enrollment_state' => 'active',
          'role' => 'StudentEnrollment'
        }]
      } end

      def basic_attributes(user)
        {
          ldap_uid: user['login_id'],
          first_name: user['first_name'],
          last_name: user['last_name'],
          email_address: user['email'],
          official_bmail_address: user['bmail']
        }
      end

      def create_mailing_list_members(*users)
        users.each do |user|
          MailingLists::Member.create!(
            mailing_list_id: list.id,
            first_name: user['first_name'],
            last_name: user['last_name'],
            email_address: user['email'],
            welcomed_at: DateTime.now,
            can_send: Canvas::CourseUser.has_instructing_role?(user)
          )
        end
      end

      before do
        allow(Canvas::CourseUsers).to receive(:new).and_return course_users
        expect(course_users).to receive(:course_users).exactly(1).times.and_return(statusCode: 200, body: canvas_site_members)
        expect(User::BasicAttributes).to receive(:attributes_for_uids).exactly(1).times.and_return campus_member_attributes
      end

      let(:campus_member_attributes) do
        canvas_site_members.map { |user| basic_attributes user }
      end

      def expect_empty_population_results(list, action)
        expect(list.population_results[action][:total]).to eq 0
        expect(list.population_results[action][:success]).to eq 0
        expect(list.population_results[action][:failure]).to eq []
      end

      context 'populating an empty list' do
        let(:canvas_site_members) { [oliver, ray, paul] }

        it 'requests addition and reports success' do
          expect(list.members.count).to eq 0

          expect(MailingLists::Member).to receive(:create!).exactly(3).times.and_call_original
          expect_any_instance_of(MailingLists::Member).not_to receive(:destroy)
          list.populate

          expect(list.population_results[:add][:success]).to eq 3
          expect_empty_population_results(list, :remove)
          expect_empty_population_results(list, :update)

          expect(response['populationResults']['success']).to eq true
          expect(response['populationResults']['messages']).to eq ['3 new members were added.']
          expect(list.members.count).to eq 3
        end

        context 'different email addresses from SIS and Canvas' do
          let(:canvas_site_members) do
            [
              oliver.merge('email' => 'oheyer@compuserve.com'),
              ray.merge('email' => 'raydavis@altavista.digital.com'),
              paul.merge(
                'email' => nil,
                'enrollments' => [{
                  'enrollment_state' => 'invited',
                  'role' => 'TaEnrollment'
                }]
              )
            ]
          end
          let(:campus_member_attributes) do
            [oliver, ray, paul].map { |user| basic_attributes user }
          end
          let(:member_addresses) { list.members.reload.map { |member| member.email_address} }

          before do
            allow(Settings.canvas_mailing_lists).to receive(:preferred_email_address_source).and_return preferred_email_address_source
            list.populate
          end

          context 'LDAP alternateId addresses not preferred' do
            let(:preferred_email_address_source) { 'ldapAlternateId' }
            it 'should use official bmail addresses' do
              expect(member_addresses).to match_array %w(oheyer@berkeley.edu raydavis@berkeley.edu kerschen@berkeley.edu)
            end
          end

          context 'LDAP mail addresses preferred' do
            let(:preferred_email_address_source) { 'ldapMail' }
            it 'should use LDAP mail addresses' do
              expect(member_addresses).to match_array %w(oheyer@classics.berkeley.edu raydavis@cogsci.berkeley.edu kerschen@english.berkeley.edu)
            end
          end

          context 'Canvas email addresses preferred' do
            let(:preferred_email_address_source) { 'canvas' }
            it 'should use Canvas addresses if available but skip pending invitees' do
              expect(member_addresses).to match_array %w(oheyer@compuserve.com raydavis@altavista.digital.com)
            end
          end
        end

        shared_examples 'a member with sending permissions' do |can_send|
          before { oliver['enrollments'][0]['role'] = role }
          it 'correctly sets sending permissions' do
            list.populate
            expect(list.members.find_by(email_address: 'oheyer@classics.berkeley.edu').can_send).to eq can_send
          end
        end

        context 'welcome email configured' do
          it 'welcomes everybody' do
            expect_any_instance_of(Mailgun::SendMessage).to receive(:post).with(hash_including(
              'from' => 'bCourses Mailing Lists <no-reply@bcourses-mail.berkeley.edu>',
              'subject' => welcome_email_subject,
              'html' => welcome_email_body,
              'text' => expected_welcome_email_text,
              'to' => an_object_having_attributes(length: 3, sort: [paul['email'], oliver['email'], ray['email']])
            )).exactly(:once).and_call_original
            list.populate
            expect(csv_row_count list).to eq 3
            expect(list.members.reload.map(&:welcomed_at)).to all(be_an_instance_of ActiveSupport::TimeWithZone)
            expect(JSON.parse(list.to_json)['mailingList']['welcomeEmailLastSent']).to be_present
          end
        end

        context 'welcome email paused' do
          let(:welcome_email_active) { false }
          it 'welcomes nobody' do
            expect_any_instance_of(Mailgun::SendMessage).not_to receive(:post)
            list.populate
            expect(csv_row_count list).to eq 0
            expect(list.members.reload.map(&:welcomed_at)).to eq [nil, nil, nil]
            expect(JSON.parse(list.to_json)['mailingList']['welcomeEmailLastSent']).to be_nil
          end
        end

        context 'welcome email without body' do
          let(:welcome_email_body) { '' }
          it 'welcomes nobody' do
            expect_any_instance_of(Mailgun::SendMessage).not_to receive(:post)
            list.populate
            expect(csv_row_count list).to eq 0
            expect(list.members.reload.map(&:welcomed_at)).to eq [nil, nil, nil]
            expect(JSON.parse(list.to_json)['mailingList']['welcomeEmailLastSent']).to be_nil
          end
        end

        context 'welcome email without subject' do
          let(:welcome_email_subject) { '' }
          it 'welcomes nobody' do
            expect_any_instance_of(Mailgun::SendMessage).not_to receive(:post)
            list.populate
            expect(csv_row_count list).to eq 0
            expect(list.members.reload.map(&:welcomed_at)).to eq [nil, nil, nil]
            expect(JSON.parse(list.to_json)['mailingList']['welcomeEmailLastSent']).to be_nil
          end
        end

        context 'teacher role' do
          let(:role) { 'TeacherEnrollment' }
          it_should_behave_like 'a member with sending permissions', true
        end

        context 'student role' do
          let(:role) { 'StudentEnrollment' }
          it_should_behave_like 'a member with sending permissions', false
        end

        context 'TA role' do
          let(:role) { 'TaEnrollment' }
          it_should_behave_like 'a member with sending permissions', true
        end

        context 'lead TA role' do
          let(:role) { 'Lead TA' }
          it_should_behave_like 'a member with sending permissions', true
        end

        context 'reader role' do
          let(:role) { 'Reader' }
          it_should_behave_like 'a member with sending permissions', true
        end

        context 'owner role' do
          let(:role) { 'Owner' }
          it_should_behave_like 'a member with sending permissions', true
        end

        context 'maintainer role' do
          let(:role) { 'Maintainer' }
          it_should_behave_like 'a member with sending permissions', true
        end

        context 'member role' do
          let(:role) { 'Member' }
          it_should_behave_like 'a member with sending permissions', false
        end
      end

      context 'no change in list membership' do
        let(:canvas_site_members) { [oliver, ray, paul] }
        before { create_mailing_list_members(oliver, ray, paul) }

        it 'makes no changes' do
          expect(list.members.count).to eq 3
          expect(MailingLists::Member).not_to receive(:create!)
          expect_any_instance_of(MailingLists::Member).not_to receive(:destroy)
          expect_any_instance_of(MailingLists::Member).not_to receive(:update)
          list.populate
          expect(list.members.count).to eq 3
        end

        it 'returns time, no errors and empty results' do
          list.populate
          expect(response['mailingList']['timeLastPopulated']).to be_present
          expect(response).not_to include 'errorMessages'
          expect_empty_population_results(list, :add)
          expect_empty_population_results(list, :remove)
          expect_empty_population_results(list, :update)
          expect(response['populationResults']['success']).to eq true
          expect(response['populationResults']['messages']).to eq []
        end
      end

      context 'new users in course site' do
        let(:canvas_site_members) { [oliver, ray, paul] }
        before { create_mailing_list_members(oliver) }

        it 'requests addition of new users only' do
          expect(list.members.count).to eq 1
          expect(csv_row_count list).to eq 1

          expect(MailingLists::Member).to receive(:create!).exactly(1).times.with(
            email_address: 'raydavis@cogsci.berkeley.edu',
            first_name: 'Ray',
            last_name: 'Davis',
            can_send: false,
            mailing_list_id: list.id
          ).and_call_original
          expect(MailingLists::Member).to receive(:create!).exactly(1).times.with(
            email_address: 'kerschen@english.berkeley.edu',
            first_name: 'Paul',
            last_name: 'Kerschen',
            can_send: false,
            mailing_list_id: list.id
          ).and_call_original
          expect_any_instance_of(MailingLists::Member).not_to receive(:destroy)

          list.populate

          expect(list.population_results[:add][:total]).to eq 2
          expect(list.population_results[:add][:success]).to eq 2
          expect(list.population_results[:add][:failure]).to eq []
          expect_empty_population_results(list, :remove)
          expect_empty_population_results(list, :update)

          expect(response['populationResults']['success']).to eq true
          expect(response['populationResults']['messages']).to eq ['2 new members were added.']

          expect(list.members.count).to eq 3
          expect(csv_row_count list).to eq 3
          expect(list.members.reload.map(&:welcomed_at)).to all(be_an_instance_of ActiveSupport::TimeWithZone)
          expect(JSON.parse(list.to_json)['mailingList']['welcomeEmailLastSent']).to be_present
        end

        it 'welcomes new users only' do
          expect_any_instance_of(Mailgun::SendMessage).to receive(:post).with(hash_including(
            'from' => 'bCourses Mailing Lists <no-reply@bcourses-mail.berkeley.edu>',
            'subject' => welcome_email_subject,
            'html' => welcome_email_body,
            'text' => expected_welcome_email_text,
            'to' => an_object_having_attributes(length: 2, sort: [paul['email'], ray['email']])
          )).exactly(:once).and_call_original
          list.populate
          expect(csv_row_count list).to eq 3
          expect(list.members.reload.map(&:welcomed_at)).to all(be_an_instance_of ActiveSupport::TimeWithZone)
          expect(JSON.parse(list.to_json)['mailingList']['welcomeEmailLastSent']).to be_present
        end
      end

      context 'users no longer in course site' do
        let(:canvas_site_members) { [oliver, ray] }
        before { create_mailing_list_members(oliver, ray, paul) }

        it 'requests removal of departed users only' do
          expect(list.members.count).to eq 3

          expect(MailingLists::Member).not_to receive(:create!)
          expect_any_instance_of(MailingLists::Member).to receive(:update).exactly(1).times.with(deleted_at: anything).and_call_original

          list.populate

          expect_empty_population_results(list, :add)
          expect(list.population_results[:remove][:total]).to eq 1
          expect(list.population_results[:remove][:success]).to eq 1
          expect(list.population_results[:remove][:failure]).to eq []
          expect(response['populationResults']['success']).to eq true
          expect(response['populationResults']['messages']).to eq ['1 former member was removed.']

          list.members.reload
          expect(list.members.count).to eq 3
          expect(list.members.select { |m| m.deleted_at.nil? }.count).to eq 2
          expect(list.members.find { |member| member.email_address == 'kerschen@english.berkeley.edu'}.deleted_at).to be_present
        end

        it 'welcomes nobody' do
          expect_any_instance_of(Mailgun::SendMessage).not_to receive(:post)
          list.populate
        end

        context 'user removed and returned' do
          let (:course_users_including_returned) { {statusCode: 200, body: canvas_site_members + [paul]} }
          let (:member_attributes_including_returned) { campus_member_attributes + [basic_attributes(paul)] }

          before do
            expect(course_users).to receive(:course_users).exactly(1).times.and_return(course_users_including_returned)
            expect(User::BasicAttributes).to receive(:attributes_for_uids).exactly(1).times.and_return(member_attributes_including_returned)
          end

          it 'can resurrect a departed user from the grave, without resending welcome email' do
            list.populate
            list.members.reload
            expect(list.members.count).to eq 3
            expect(csv_row_count list).to eq 3
            expect(list.active_members.count).to eq 2
            expect(list.members.find { |member| member.email_address == 'kerschen@english.berkeley.edu'}.deleted_at).to be_present

            expect_any_instance_of(Mailgun::SendMessage).not_to receive(:post)
            list.populate
            list.members.reload
            expect(list.members.count).to eq 3
            expect(csv_row_count list).to eq 3
            expect(list.active_members.count).to eq 3
            expect(list.members.find { |member| member.email_address == 'kerschen@english.berkeley.edu'}.deleted_at).to be_nil
          end
        end
      end

      context 'user with changed permissions' do
        let(:canvas_site_members) { [oliver, ray, paul] }
        before do
          student_oliver = oliver.merge({'enrollments' => [{'role' => 'StudentEnrollment'}]})
          create_mailing_list_members(student_oliver, ray, paul)
        end

        it 'updates user\'s sending permission' do
          expect(list.members.count).to eq 3
          expect(list.members.find_by(email_address: 'oheyer@classics.berkeley.edu').can_send).to eq false

          expect(MailingLists::Member).not_to receive(:create!)
          expect_any_instance_of(MailingLists::Member).not_to receive(:destroy)
          expect_any_instance_of(MailingLists::Member).to receive(:update).exactly(1).times.and_call_original

          list.populate

          expect(list.members.count).to eq 3
          expect(list.members.find_by(email_address: 'oheyer@classics.berkeley.edu').can_send).to eq true

          expect_empty_population_results(list, :add)
          expect_empty_population_results(list, :remove)
          expect(list.population_results[:update][:total]).to eq 1
          expect(list.population_results[:update][:success]).to eq 1
          expect(list.population_results[:update][:failure]).to eq []
          expect(response['populationResults']['success']).to eq true
          expect(response['populationResults']['messages']).to eq ['1 member was updated.']
        end

        it 'welcomes nobody' do
          expect_any_instance_of(Mailgun::SendMessage).not_to receive(:post)
          list.populate
        end
      end
    end
  end

end
