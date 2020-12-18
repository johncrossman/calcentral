module Oec
  module Worksheets

    DEFAULT_EXPORT_PATH = Pathname.new Settings.oec.local_write_directory
    WORKSHEET_DATE_FORMAT = '%m-%d-%Y'

    class Base
      include Enumerable

      attr_accessor :export_directory

      class << self
        attr_accessor :row_validations

        def init_validations
          self.row_validations ||= []
        end

        def inherited(subclass)
          subclass.init_validations
        end
      end

      def self.validate(key, &blk)
        self.row_validations << {key: key, blk: blk}
      end

      def self.capitalize_keys(row)
        row.inject({}) do |caps_hash, (key, value)|
          caps_hash[key.upcase] = value
          caps_hash
        end
      end

      def self.dept_form_from_name(dept_name)
        # Make DEPT_FORM safe for Explorance scripts.
        if dept_name
          dept_name.gsub(/,/, '_')
        else
          dept_name
        end
      end

      def self.export_name
        self.name.demodulize.underscore
      end

      def self.from_csv(csv, opts={})
        return unless csv && (parsed_csv = CSV.parse csv)
        instance = self.new opts
        (header_row = parsed_csv.shift) until (header_row == instance.headers || parsed_csv.empty?)
        unless header_row == instance.headers
          csv_snippet = csv[0..499]
          csv_snippet << '...' if csv.length > 500
          raise ArgumentError, "Header mismatch: cannot create instance of #{self.name} from CSV: '#{csv_snippet}'"
        end
        parsed_csv.each_with_index { |row, index| instance[index] = instance.parse_row row  }
        instance
      end

      def self.string_coords(y, x)
        # e.g., [1, 4] to D1
        "#{('A'..'Z').first(x).last}#{y}"
      end

      def errors_for_row(row)
        errors = self.class.row_validations.map do |validation|
          if row[validation[:key]].blank?
            "Blank #{validation[:key]}"
          elsif (message = validation[:blk].call row)
            "#{message} #{validation[:key]} #{row[validation[:key]]}"
          end
        end
        errors.compact
      end

      def initialize(opts={})
        @export_directory = opts[:export_path] || DEFAULT_EXPORT_PATH
        FileUtils.mkdir_p @export_directory unless File.exist? @export_directory
        @opts = opts
        @rows = ActiveSupport::OrderedHash.new
      end

      def [](key)
        @rows[key]
      end

      def []=(key, value)
        @rows[key] = Oec::Worksheets::Row.new(value, self)
      end

      def count
        @rows.count
      end

      def csv_export_path
        @export_directory.join "#{export_name}.csv"
      end

      def each
        @rows.values.each { |row| yield row }
      end

      def each_sorted
        sorted_rows.each { |row| yield row }
      end

      def each_sorted_with_index
        sorted_rows.each_with_index { |row, i| yield row, i }
      end

      def export_name
        @opts[:export_name] || self.class.export_name
      end

      # Column names that may be assigned to rows and will be included in CSV export. Subclasses must override.
      def headers; end

      # Column names that may be assigned to rows but will not be included in CSV export. Subclasses may override.
      def transient_headers
        []
      end

      def parse_row(row)
        parsed_row = Hash[self.headers.zip row]
        %w(START_DATE END_DATE).each do |date_header|
          if parsed_row[date_header]
            # Parse dash or slash separators, with or without leading zeros; output leading zeros and dash separators.
            begin
              parsed_row[date_header] = Date.strptime(parsed_row[date_header].tr('/', '-'), WORKSHEET_DATE_FORMAT).strftime(WORKSHEET_DATE_FORMAT)
            rescue ArgumentError
              raise StandardError, "Could not parse #{date_header} value: '#{parsed_row[date_header]}'"
            end
          end
        end
        Oec::Worksheets::Row.new(parsed_row, self)
      end

      def sorted_rows
        # Subclasses may override to define an ordering.
        @rows.values
      end

      def to_csv_string
        CSV.generate do |csv|
          csv << headers
          each_sorted do |row|
            csv_row = headers.map do |header|
              # A trick to force plaintext formatting in Google Sheets.
              # TODO Why not use the CSV :force_quotes option?
              row[header] =~ /\A\d+\Z/ ? "'#{row[header]}" : row[header]
            end
            csv << csv_row
          end
        end
      end

      def to_io
        StringIO.new(to_csv_string)
      end

      def write_csv
        if @rows.any?
          output = CSV.open(csv_export_path, 'wb', headers: headers, write_headers: true)
          sorted_rows.each { |row| output << row.to_hash }
        else
          output = CSV.open(csv_export_path, 'wb')
          output << headers
        end
        output.close
      end
    end
  end
end
