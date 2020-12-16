describe Oec::Tasks::TermSetup do

  let(:term_code) { '2013-B' }
  let(:today) { '2015-08-31' }
  let(:now) { '09:22:22' }
  let(:logfile) { "#{now} term setup task.log" }
  before { allow(DateTime).to receive(:now).and_return DateTime.strptime("#{today} #{now}", '%F %H:%M:%S') }

  subject { described_class.new(term_code: term_code, allow_past_term: true) }

  let (:fake_remote_drive) { double() }
  before { allow(Oec::RemoteDrive).to receive(:new).and_return fake_remote_drive }

  shared_context 'remote drive interaction' do
    before(:each) do
      allow(fake_remote_drive).to receive(:find_first_matching_folder).and_return mock_google_drive_item
      allow(fake_remote_drive).to receive(:find_first_matching_item).and_return mock_google_drive_item
      allow(fake_remote_drive).to receive(:find_nested).and_return mock_google_drive_item
    end

    let(:term_folder) { mock_google_drive_item term_code }
    let(:logs_today_folder) { mock_google_drive_item today }
    let(:overrides_folder) { mock_google_drive_item Oec::Folder.overrides }
    let(:tracking_worksheet) { double(:[]= => true, save: true) }
    let(:tracking_spreadsheet) { double(worksheets: [tracking_worksheet]) }

    before do
      expect(fake_remote_drive).to receive(:find_folders).with(no_args).and_return []
      expect(fake_remote_drive).to receive(:check_conflicts_and_create_folder)
        .with(term_code, nil, anything).and_return term_folder

      [:confirmations, :logs, :merged_confirmations, :published, :sis_imports].each do |folder_type|
        expect(fake_remote_drive).to receive(:check_conflicts_and_create_folder)
          .with(Oec::Folder::FOLDER_NAMES[folder_type], term_folder, anything)
          .and_return mock_google_drive_item(Oec::Folder::FOLDER_NAMES[folder_type])
      end

      expect(fake_remote_drive).to receive(:check_conflicts_and_create_folder)
        .with(Oec::Folder.overrides, term_folder, anything).and_return overrides_folder

      expect(fake_remote_drive).to receive(:copy_item_to_folder)
        .with(anything, "#{Oec::Folder.confirmations}_id", 'TEMPLATE').and_return mock_google_drive_item

      %w(courses course_instructors course_supervisors instructors supervisors).each do |sheet|
        expect(fake_remote_drive).to receive(:check_conflicts_and_upload)
          .with(kind_of(Oec::Worksheets::Base), sheet, Oec::Worksheets::Base, overrides_folder, anything)
          .and_return mock_google_drive_item(sheet)
      end

      expect(fake_remote_drive).to receive(:copy_item_to_folder)
        .with(anything, "#{term_code}_id", 'Spring 2013 Course Evaluations Tracking Sheet').and_return double(id: 'tracking_sheet_id')

      expect(fake_remote_drive).to receive(:spreadsheet_by_id).with('tracking_sheet_id').and_return tracking_spreadsheet

      expect(fake_remote_drive).to receive(:check_conflicts_and_create_folder)
        .with(today, anything, anything).and_return logs_today_folder
      expect(fake_remote_drive).to receive(:check_conflicts_and_upload)
        .with(kind_of(Pathname), logfile, 'text/plain', logs_today_folder, anything)
        .and_return mock_google_drive_item(logfile)
    end
  end

  context 'successful term setup' do
    include_context 'remote drive interaction'
    it 'creates folders, uploads sheets, and writes log' do
      subject.run
    end
  end

  context 'logging to cache' do
    let(:api_task_id) { Oec::ApiTaskWrapper.generate_task_id }
    subject do
      described_class.new({
        api_task_id: api_task_id,
        log_to_cache: true,
        term_code: term_code,
        allow_past_term: true
      })
    end
    include_context 'remote drive interaction'

    it 'allows status and log retrieval by cache key' do
      subject.run
      task_status = Oec::Tasks::Base.fetch_from_cache api_task_id
      expect(task_status[:status]).to eq 'Success'
      expect(task_status[:log]).to have_at_least(3).items
      expect(task_status[:log][0]).to include 'Starting Oec::Tasks::TermSetup'
      expect(task_status[:log][1]).to include 'Will create initial folders and files'
      expect(task_status[:log].last).to include 'Exporting log file'
    end
  end

  context 'Google Drive connection error' do
    context 'on initialization' do
      before { allow(Oec::RemoteDrive).to receive(:new).and_raise Signet::AuthorizationError, 'Authorization failed.' }
      it 'returns a comprehensible error' do
        expect(Rails.logger).to receive(:error).exactly(1).times.with /Error connecting to Google Drive/
        subject.run
      end
    end

    context 'during run' do
      before do
        expect(fake_remote_drive).to receive(:check_conflicts_and_create_folder).at_least(1).times
          .and_raise Errors::ProxyError, 'A confounding error'
        expect(fake_remote_drive).to receive(:find_nested).at_least(1).times
          .and_raise Errors::ProxyError, 'A confounding error'
      end

      it 'logs errors' do
        expect(Rails.logger).to receive(:error).at_least(1).times do |error_message|
          expect(error_message.lines.first).to include 'A confounding error'
        end
        subject.run
      end
    end
  end

  context 'local-write mode' do
    subject { described_class.new(term_code: term_code, local_write: 'Y', allow_past_term: true) }

    before do
      allow(fake_remote_drive).to receive(:find_nested).and_return mock_google_drive_item
      expect(fake_remote_drive).to receive(:find_folders).with(no_args).and_return []
    end

    it 'reads from but does not write to remote drive' do
      expect(fake_remote_drive).not_to receive(:check_conflicts_and_upload)
      expect(fake_remote_drive).not_to receive(:copy_item_to_folder)
      subject.run
    end

    it 'sets default term dates as overrides' do
      subject.run
      courses = Oec::Worksheets::Courses.from_csv File.read(Rails.root.join 'tmp', 'oec', 'courses.csv')
      expect(courses.first.to_hash).to include({
        'START_DATE' => '01-29-2013',
        'END_DATE' => '05-07-2013'
      })
    end
  end

  context 'not explicitly told that past terms are allowed' do
    subject { described_class.new(term_code: term_code, local_write: 'Y') }
    before do
      allow(fake_remote_drive).to receive(:find_nested).and_return mock_google_drive_item
    end
    it 'refuses to run' do
      expect(Rails.logger).to receive(:error).with /Past ending date/
      subject.run
    end
  end
end
