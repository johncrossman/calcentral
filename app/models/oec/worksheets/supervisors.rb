module Oec
  module Worksheets
    class Supervisors < Base

      def headers
        %w(
          LDAP_UID
          SIS_ID
          FIRST_NAME
          LAST_NAME
          EMAIL_ADDRESS
          SUPERVISOR_GROUP
          PRIMARY_ADMIN
          SECONDARY_ADMIN
          DEPT_NAME_1
          DEPT_NAME_2
          DEPT_NAME_3
          DEPT_NAME_4
          DEPT_NAME_5
          DEPT_NAME_6
          DEPT_NAME_7
          DEPT_NAME_8
          DEPT_NAME_9
          DEPT_NAME_10
        )
      end

      def matching_dept_form(dept_form)
        return [] if dept_form.blank?
        select do |row|
          (1..10).map { |i| self.class.dept_form_from_name(row["DEPT_NAME_#{i}"]) }.include? dept_form
        end
      end

      def matching_dept_name(dept_name)
        return [] if dept_name.blank?
        select do |row|
          (1..10).map { |i| row["DEPT_NAME_#{i}"] }.include? dept_name
        end
      end

      validate('LDAP_UID') { |row| 'Non-numeric' unless row['LDAP_UID'] =~ /\A\d+\Z/ }
      validate('SIS_ID') { |row| 'Unexpected' unless row['SIS_ID'] == "UID:#{row['LDAP_UID']}" || row['SIS_ID'] =~ /\A\d+\Z/ }

    end
  end
end
