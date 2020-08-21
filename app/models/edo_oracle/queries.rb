module EdoOracle
  class Queries < Connection
    include ActiveRecordHelper
    include ClassLogger
    include Concerns::QueryHelper

    ABSENTIA_CODE = 'OGPFABSENT'.freeze
    FILING_FEE_CODE = 'BGNNFILING'.freeze

    CANONICAL_SECTION_ORDERING = 'section_display_name, "primary" DESC, instruction_format, section_num'

    SECTION_COLUMNS = <<-SQL
      sec."id" AS section_id,
      sec."term-id" AS term_id,
      sec."session-id" AS session_id,
      TRIM(crs."title") AS course_title,
      TRIM(crs."transcriptTitle") AS course_title_short,
      crs."subjectArea" AS dept_name,
      crs."classSubjectArea" AS dept_code,
      crs."academicCareer-code" AS course_career_code,
      sec."primary" AS "primary",
      sec."sectionNumber" AS section_num,
      sec."component-code" AS instruction_format,
      sec."instructionMode-code" AS instruction_mode,
      TO_CHAR(sec."primaryAssociatedSectionId") AS primary_associated_section_id,
      sec."displayName" AS section_display_name,
      sec."topic-descr" AS topic_description,
      xlat."courseDisplayName" AS course_display_name,
      crs."catalogNumber-formatted" AS catalog_id,
      crs."catalogNumber-number" AS catalog_root,
      crs."catalogNumber-prefix" AS catalog_prefix,
      crs."catalogNumber-suffix" AS catalog_suffix
    SQL

    JOIN_SECTION_TO_COURSE = <<-SQL
      LEFT OUTER JOIN SISEDO.DISPLAYNAMEXLATV01_MVW xlat ON (
        xlat."classDisplayName" = sec."displayName")
      LEFT OUTER JOIN SISEDO.API_COURSEV01_MVW crs ON (
        xlat."courseDisplayName" = crs."displayName")
    SQL

    JOIN_ROSTER_TO_EMAIL = <<-SQL
       LEFT OUTER JOIN SISEDO.PERSON_EMAILV00_VW email ON (
         email."PERSON_KEY" = enroll."STUDENT_ID" AND
         email."EMAIL_PRIMARY" = 'Y')
    SQL

    def self.where_course_term
      sql_clause = <<-SQL
        AND term.ACAD_CAREER = crs."academicCareer-code"
        AND term.STRM = sec."term-id"
        AND CAST(crs."fromDate" AS DATE) <= term.TERM_END_DT
        AND CAST(crs."toDate" AS DATE) >= term.TERM_END_DT
      SQL
      sql_clause
    end

    def self.where_course_term_updated_date
      sql_clause = <<-SQL
        AND crs."updatedDate" = (
          SELECT MAX(crs2."updatedDate")
          FROM SISEDO.API_COURSEV01_MVW crs2, SISEDO.EXTENDED_TERM_MVW term2
          WHERE crs2."cms-version-independent-id" = crs."cms-version-independent-id"
          AND crs2."displayName" = crs."displayName"
          AND term2.ACAD_CAREER = crs."academicCareer-code"
          AND term2.STRM = sec."term-id"
          AND (
            (
              CAST(crs2."fromDate" AS DATE) <= term2.TERM_END_DT AND
              CAST(crs2."toDate" AS DATE) >= term2.TERM_END_DT
            )
            OR CAST(crs2."updatedDate" AS DATE) = TO_DATE('1901-01-01', 'YYYY-MM-DD')
          )
        )
      SQL
      sql_clause
    end

    def self.and_academic_career(object_alias, academic_careers)
      return nil if academic_careers.blank?
      <<-SQL
        AND #{object_alias}.ACAD_CAREER IN ('#{academic_careers.join "','"}')
      SQL
    end

    def self.join_requirements_designation(object_alias, require_desig_code)
      return nil if require_desig_code.blank?
      <<-SQL
      LEFT OUTER JOIN SISEDO.CLC_RQMNT_DESIG_DESCR RD
        ON #{object_alias}.ACAD_CAREER = RD.ACAD_CAREER
       AND #{object_alias}.INSTITUTION = RD.INSTITUTION
       AND #{object_alias}.TERM_ID = RD.TERM_ID
       AND RD.RQMNT_DESIGNTN = '#{require_desig_code}'
      SQL
    end

    def self.get_basic_people_attributes(up_to_1000_ldap_uids)
      safe_query <<-SQL
        select pi.ldap_uid, trim(pi.first_name) as first_name, trim(pi.last_name) as last_name, 
          pi.email_address, pi.student_id, pi.affiliations, pi.person_type, pi.alternateid
        from sisedo.calcentral_person_info_vw pi
        where pi.ldap_uid in (#{up_to_1000_ldap_uids.collect { |id| id.to_i }.join(', ')})
      SQL
    end

    def self.get_enrolled_sections(person_id, terms)
      # The push_pred hint below alerts Oracle to use indexes on SISEDO.API_COURSEV00_VW, aka crs.
      in_term_where_clause = "enr.\"TERM_ID\" IN (#{terms_query_list terms}) AND" unless terms.nil?
      safe_query <<-SQL
        SELECT DISTINCT
          #{SECTION_COLUMNS},
          sec."maxEnroll" AS enroll_limit,
          ENR.STDNT_ENRL_STATUS_CODE AS enroll_status,
          ENR.WAITLISTPOSITION AS waitlist_position,
          ENR.UNITS_TAKEN,
          ENR.UNITS_EARNED,
          ENR.GRADE_MARK AS grade,
          ENR.GRADE_POINTS AS grade_points,
          ENR.GRADING_BASIS_CODE AS grading_basis,
          ENR.ACAD_CAREER,
          CASE
            WHEN ENR.COURSE_CAREER = 'LAW'
            THEN ENR.RQMNT_DESIGNTN
            ELSE NULL
          END AS RQMNT_DESIGNTN
        FROM SISEDO.EXTENDED_TERM_MVW term,
             SISEDO.ETS_ENROLLMENTV01_VW enr
        JOIN SISEDO.CLASSSECTIONALLV01_MVW sec ON (
          enr."TERM_ID" = sec."term-id" AND
          enr."SESSION_ID" = sec."session-id" AND
          enr."CLASS_SECTION_ID" = sec."id" AND
          sec."status-code" IN ('A','S') )
        #{JOIN_SECTION_TO_COURSE}
        WHERE  #{in_term_where_clause}
          enr."CAMPUS_UID" = '#{person_id}'
          #{and_institution('enr')}
          AND enr."STDNT_ENRL_STATUS_CODE" != 'D'
          #{where_course_term}
          #{where_course_term_updated_date}
        ORDER BY term_id DESC, #{CANONICAL_SECTION_ORDERING}
      SQL
    end

    def self.get_instructing_sections(person_id, terms = nil)
      # Reduce performance hit and only add Terms whare clause if limiting number of terms pulled
      in_term_where_clause = " AND instr.\"term-id\" IN (#{terms_query_list terms})" unless terms.nil?
      safe_query <<-SQL
        SELECT
          #{SECTION_COLUMNS},
          sec."cs-course-id" AS cs_course_id,
          sec."maxEnroll" AS enroll_limit,
          sec."maxWaitlist" AS waitlist_limit,
          sec."startDate" AS start_date,
          sec."endDate" AS end_date
        FROM SISEDO.EXTENDED_TERM_MVW term,
             SISEDO.ASSIGNEDINSTRUCTORV00_VW instr
        JOIN SISEDO.CLASSSECTIONALLV01_MVW sec ON (
          instr."term-id" = sec."term-id" AND
          instr."session-id" = sec."session-id" AND
          instr."cs-course-id" = sec."cs-course-id" AND
          instr."offeringNumber" = sec."offeringNumber" AND
          instr."number" = sec."sectionNumber")
        #{JOIN_SECTION_TO_COURSE}
        WHERE sec."status-code" IN ('A','S')
          #{in_term_where_clause}
          AND instr."campus-uid" = '#{person_id}'
          #{where_course_term}
          #{where_course_term_updated_date}
        ORDER BY term_id DESC, #{CANONICAL_SECTION_ORDERING}
      SQL
    end

    def self.get_instructing_legacy_terms(person_id)
      safe_query <<-SQL
        SELECT "STRM" as term_id
        FROM SISEDO.CLC_TERM_INSTR_BF2008V00_VW
        WHERE "INSTRUCTOR_ID" = '#{person_id}'
      SQL
    end

    def self.get_associated_secondary_sections(term_id, section_id)
      safe_query <<-SQL
        SELECT DISTINCT
          #{SECTION_COLUMNS},
          sec."cs-course-id" AS cs_course_id,
          sec."maxEnroll" AS enroll_limit,
          sec."maxWaitlist" AS waitlist_limit
        FROM SISEDO.CLASSSECTIONALLV01_MVW sec
        #{JOIN_SECTION_TO_COURSE}
        WHERE sec."status-code" IN ('A','S')
          AND sec."primary" = 'false'
          AND sec."term-id" = '#{term_id}'
          AND sec."primaryAssociatedSectionId" = '#{section_id}'
          #{where_course_term_updated_date}
        ORDER BY #{CANONICAL_SECTION_ORDERING}
      SQL
    end

    def self.get_section_meetings(term_id, section_id)
      safe_query <<-SQL
        SELECT DISTINCT
          sec."id" AS section_id,
          sec."printInScheduleOfClasses" AS print_in_schedule_of_classes,
          mtg."term-id" AS term_id,
          mtg."session-id" AS session_id,
          mtg."location-descr" AS location,
          mtg."meetsDays" AS meeting_days,
          mtg."startTime" AS meeting_start_time,
          mtg."endTime" AS meeting_end_time,
          mtg."startDate" AS meeting_start_date,
          mtg."endDate" AS meeting_end_date
        FROM
          SISEDO.MEETINGV00_VW mtg
        JOIN SISEDO.CLASSSECTIONALLV01_MVW sec ON (
          mtg."cs-course-id" = sec."cs-course-id" AND
          mtg."term-id" = sec."term-id" AND
          mtg."session-id" = sec."session-id" AND
          mtg."offeringNumber" = sec."offeringNumber" AND
          mtg."sectionNumber" = sec."sectionNumber"
        )
        WHERE
          sec."term-id" = '#{term_id}' AND
          sec."id" = '#{section_id}'
        ORDER BY meeting_start_date, meeting_start_time
      SQL
    end

    def self.get_section_final_exams(term_id, section_id)
      safe_query <<-SQL
      SELECT
        sec."term-id" AS term_id,
        sec."session-id" AS session_id,
        sec."id" AS section_id,
        sec."finalExam" AS exam_type,
        exam."EXAM_DT" AS exam_date,
        exam."EXAM_START_TIME" AS exam_start_time,
        exam."EXAM_END_TIME" AS exam_end_time,
        exam."EXAM_EXCEPTION" as exam_exception,
        exam."FACILITY_DESCR" AS location,
        exam."FINALIZED" AS finalized
      FROM
        SISEDO.CLASSSECTIONALLV01_MVW sec
      LEFT JOIN SISEDO.CLC_FINAL_EXAM_INFOV00_VW exam ON (
        sec."cs-course-id" = exam."CRSE_ID" AND
        sec."term-id" = exam."STRM" AND
        sec."session-id" = exam."SESSION_CODE" AND
        sec."offeringNumber" = exam."CRSE_OFFER_NBR" AND
        sec."sectionNumber" = exam."CLASS_SECTION"
      )
      WHERE
        sec."term-id" = '#{term_id}' AND
        sec."id" = '#{section_id}'
      ORDER BY exam_date
      SQL
    end

    def self.get_sections_by_ids(term_id, section_ids)
      safe_query <<-SQL
        SELECT DISTINCT
          #{SECTION_COLUMNS}
        FROM SISEDO.CLASSSECTIONALLV01_MVW sec
        #{JOIN_SECTION_TO_COURSE}
        WHERE sec."term-id" = '#{term_id}'
          AND sec."id" IN (#{section_ids.collect { |id| id.to_i }.join(', ')})
          #{where_course_term_updated_date}
        ORDER BY #{CANONICAL_SECTION_ORDERING}
      SQL
    end

    def self.get_section_instructors(term_id, section_id)
      safe_query <<-SQL
        SELECT DISTINCT
          TRIM(instr."formattedName") AS person_name,
          TRIM(instr."givenName") AS first_name,
          TRIM(instr."familyName") AS last_name,
          instr."campus-uid" AS ldap_uid,
          instr."role-code" AS role_code,
          instr."role-descr" AS role_description,
          instr."gradeRosterAccess" AS grade_roster_access,
          instr."printInScheduleOfClasses" AS print_in_schedule
        FROM
          SISEDO.ASSIGNEDINSTRUCTORV00_VW instr
        JOIN SISEDO.CLASSSECTIONALLV01_MVW sec ON (
          instr."cs-course-id" = sec."cs-course-id" AND
          instr."term-id" = sec."term-id" AND
          instr."session-id" = sec."session-id" AND
          instr."offeringNumber" = sec."offeringNumber" AND
          instr."number" = sec."sectionNumber"
        )
        WHERE
          sec."id" = '#{section_id.to_s}' AND
          sec."term-id" = '#{term_id.to_s}' AND
          TRIM(instr."instructor-id") IS NOT NULL
        ORDER BY
          role_code
      SQL
    end

    # TODO: Update this and dependencies to require term
    def self.get_cross_listed_course_title(course_code)
      result = safe_query <<-SQL
        SELECT
          TRIM(crs."title") AS course_title,
          TRIM(crs."transcriptTitle") AS course_title_short
        FROM SISEDO.API_COURSEV01_MVW crs
        WHERE crs."updatedDate" = (
          SELECT MAX(CRS2."updatedDate") FROM SISEDO.API_COURSEV01_MVW crs2
          WHERE crs2."cms-version-independent-id" = crs."cms-version-independent-id"
          AND crs2."displayName" = crs."displayName"
        )
        AND crs."displayName" = '#{course_code}'
      SQL
      result.first if result
    end

    def self.get_subject_areas
      safe_query <<-SQL
        SELECT DISTINCT "subjectArea" FROM SISEDO.API_COURSEIDENTIFIERSV00_VW
      SQL
    end

    def self.get_enrolled_students(section_id, term_id)
      safe_query <<-SQL
        SELECT DISTINCT
          enroll."CAMPUS_UID" AS ldap_uid,
          enroll."STUDENT_ID" AS student_id,
          enroll."STDNT_ENRL_STATUS_CODE" AS enroll_status,
          enroll."WAITLISTPOSITION" AS waitlist_position,
          enroll."UNITS_TAKEN" AS units,
          TRIM(enroll."GRADING_BASIS_CODE") AS grading_basis
        FROM SISEDO.ETS_ENROLLMENTV01_VW enroll
        WHERE
          enroll."CLASS_SECTION_ID" = '#{section_id}'
          AND enroll."TERM_ID" = '#{term_id}'
          AND #{omit_drops_and_withdrawals}
      SQL
    end

    # Extended version of #get_enrolled_students used for rosters
    def self.get_rosters(ccns, term_id)
      if Settings.features.allow_alt_email_addr_for_enrollments
        join_roster_to_email = JOIN_ROSTER_TO_EMAIL
        email_col = ", email.\"EMAIL_EMAILADDRESS\" AS email_address"
      end

      safe_query <<-SQL
        SELECT DISTINCT
          enroll."CLASS_SECTION_ID" AS section_id,
          enroll."CAMPUS_UID" AS ldap_uid,
          enroll."STUDENT_ID" AS student_id,
          enroll."STDNT_ENRL_STATUS_CODE" AS enroll_status,
          enroll."WAITLISTPOSITION" AS waitlist_position,
          enroll."UNITS_TAKEN" AS units,
          enroll."ACAD_CAREER" AS academic_career,
          TRIM(enroll."GRADING_BASIS_CODE") AS grading_basis,
          plan."ACADPLAN_DESCR" AS major,
          plan."STATUSINPLAN_STATUS_CODE",
          stdgroup."HIGHEST_STDNT_GROUP" AS terms_in_attendance_group
          #{email_col}
        FROM SISEDO.ETS_ENROLLMENTV01_VW enroll
        LEFT OUTER JOIN
          SISEDO.STUDENT_PLAN_CC_V00_VW plan ON enroll."STUDENT_ID" = plan."STUDENT_ID" AND
          plan."ACADPLAN_TYPE_CODE" IN ('CRT', 'HS', 'MAJ', 'SP', 'SS')
        LEFT OUTER JOIN
          (
            SELECT s."STUDENT_ID", Max(s."STDNT_GROUP") AS "HIGHEST_STDNT_GROUP" FROM SISEDO.STUDENT_GROUPV01_VW s
            WHERE s."STDNT_GROUP" IN ('R1TA', 'R2TA', 'R3TA', 'R4TA', 'R5TA', 'R6TA', 'R7TA', 'R8TA')
            GROUP BY s."STUDENT_ID"
          ) stdgroup
          ON enroll."STUDENT_ID" = stdgroup."STUDENT_ID"
        #{join_roster_to_email}
        WHERE
          enroll."CLASS_SECTION_ID" IN ('#{ccns.join "','"}')
          AND enroll."TERM_ID" = '#{term_id}'
          AND #{omit_drops_and_withdrawals}
      SQL
    end

    def self.has_instructor_history?(ldap_uid, instructor_terms = nil)
      if instructor_terms.to_a.any?
        instructor_term_clause = "AND instr.\"term-id\" IN (#{terms_query_list instructor_terms.to_a})"
      end
      result = safe_query <<-SQL
        SELECT
          count(instr."term-id") AS course_count
        FROM
          SISEDO.ASSIGNEDINSTRUCTORV00_VW instr
        WHERE
          instr."campus-uid" = '#{ldap_uid}' AND
          rownum < 2
          #{instructor_term_clause}
      SQL
      if (result_row = result.first)
        Rails.logger.debug "Instructor #{ldap_uid} history for terms #{instructor_terms} count = #{result_row}"
        result_row['course_count'].to_i > 0
      else
        false
      end
    end

    def self.has_student_history?(ldap_uid, student_terms = nil)
      if student_terms.to_a.any?
        student_term_clause = "AND enroll.\"TERM_ID\" IN (#{terms_query_list student_terms.to_a})"
      end
      result = safe_query <<-SQL
        SELECT
          count(enroll."TERM_ID") AS enroll_count
        FROM
          SISEDO.ETS_ENROLLMENTV01_VW enroll
        WHERE
          enroll."CAMPUS_UID" = '#{ldap_uid.to_i}' AND
          rownum < 2
          #{student_term_clause}
      SQL
      if (result_row = result.first)
        Rails.logger.debug "Student #{ldap_uid} history for terms #{student_terms} count = #{result_row}"
        result_row['enroll_count'].to_i > 0
      else
        false
      end
    end

    # Used to create mapping between Legacy CCNs and CS Section IDs.
    def self.get_section_id(term_id, department, catalog_id, instruction_format, section_num)
      compressed_dept = SubjectAreas.compress department
      uglified_course_name = "#{compressed_dept} #{catalog_id}"
      rows = safe_query <<-SQL
        SELECT
          sec."id" AS section_id
        FROM
          SISEDO.CLASSSECTIONALLV01_MVW sec
        WHERE
          sec."term-id" = '#{term_id}' AND
          sec."component-code" = '#{instruction_format}' AND
          sec."displayName" = '#{uglified_course_name}' AND
          sec."sectionNumber" = '#{section_num}'
      SQL
      if (row = rows.first)
        row['section_id']
      end
    end

    def self.get_registration_status (person_id)
      safe_query <<-SQL
        SELECT STUDENT_ID as student_id,
          ACADCAREER_CODE as acadcareer_code,
          TERM_ID as term_id,
          WITHCNCL_TYPE_CODE as withcncl_type_code,
          WITHCNCL_TYPE_DESCR as withcncl_type_descr,
          WITHCNCL_REASON_CODE as withcncl_reason_code,
          WITHCNCL_REASON_DESCR as withcncl_reason_descr,
          WITHCNCL_FROMDATE as withcncl_fromdate,
          WITHCNCL_LASTATTENDDATE as withcncl_lastattendate,
          SPLSTUDYPROG_TYPE_CODE as splstudyprog_type_code,
          SPLSTUDYPROG_TYPE_DESCR as splstudyprog_type_descr
        FROM
          SISEDO.STUDENT_REGISTRATIONV01_VW
        WHERE
          STUDENT_ID = '#{person_id}' AND
          (WITHCNCL_TYPE_CODE IS NOT NULL
            OR SPLSTUDYPROG_TYPE_CODE = '#{ABSENTIA_CODE}'
            OR SPLSTUDYPROG_TYPE_CODE = '#{FILING_FEE_CODE}')
      SQL
    end

    def self.get_pnp_unit_count (student_id)
      result = safe_query <<-SQL
        SELECT STUDENT_ID,
               PNP_TOT_UNITS_TAKEN as pnp_taken,
               PNP_TOT_UNITS_PASSED as pnp_passed
        FROM (
          SELECT *
          FROM SISEDO.STUCAR_TERMV00_VW
          WHERE STUDENT_ID = #{student_id}
          ORDER BY term_id DESC)
        WHERE rownum = 1
      SQL
      result.first
    end

    def self.get_new_admit_data(student_id)
      result = safe_query <<-SQL
        SELECT
          ACAD_PROG as applicant_program,
          ADMIT_TERM as admit_term,
          ADMIT_TYPE as admit_type,
          UC_ADMITTED_GEP as global_edge_program,
          ADM_APPL_NBR as application_nbr,
          UC_ATHLETE as athlete,
          UC_EXPIRE_DT_ADTL as expiration_date,
          PROG_ACTION as admit_action,
          PROG_STATUS as admit_status
        FROM
          SYSADM.PS_UCC_AD_ADMITSIR
        WHERE
          EMPLID = '#{student_id}' AND
          (
            PROG_ACTION <> 'DATA' OR
            (PROG_REASON = 'LMAY' AND PROG_STATUS <> 'C')
          )
      SQL
      result
    end

    def self.get_transfer_credit_expiration(student_id)
      result = safe_query <<-SQL
        SELECT
          EXPIRE_DT_TC as expire_date
        FROM
          SISEDO.APPLICANT_ADMIT_DATAV00_VW
        WHERE
          STUDENT_ID = '#{student_id}' AND
          APPLICATION_CENTER = 'UGRD'
        ORDER BY APPLICATION_NBR DESC
      SQL
      result.first
    end

    def self.get_new_admit_evaluator(student_id, application_nbr)
      result = safe_query <<-SQL
        SELECT
          EVALUATOR_NAME as evaluator_name,
          EVALUATOR_EMAIL as evaluator_email
        FROM
          SISEDO.APPLICANT_ADMIT_DATAV00_VW
        WHERE
          STUDENT_ID = '#{student_id}' AND
          APPLICATION_NBR = '#{application_nbr}' AND
          APPLICATION_CENTER = 'UGRD'
      SQL
      result.first
    end

    def self.get_concurrent_student_status (student_id)
      result = safe_query <<-SQL
        SELECT
          CONCURRENT_PROGRAM as concurrent_status
        FROM
            SISEDO.CLC_CONCURRENT_PROGRAMV00_VW
          WHERE STUDENT_ID = '#{student_id}' AND
              INSTITUTION = 'UCB01'
      SQL
      result.first
    end

    def self.get_academic_standings (student_id)
      safe_query <<-SQL
        SELECT STUDENT_ID as student_id,
          ACAD_STANDING_STATUS as acad_standing_status,
          ACAD_STANDING_STATUS_DESCR as acad_standing_status_descr,
          ACAD_STANDING_ACTION_DESCR as acad_standing_action_descr,
          TERM_ID as term_id,
          ACTION_DATE as action_date
        FROM
          SISEDO.STUDENT_ACAD_STNDNGV00_VW
        WHERE
          STUDENT_ID = '#{student_id}' AND
          ACADCAREER_CODE = 'UGRD'
      SQL
    end

    def self.get_grading_dates
      safe_query <<-SQL
        SELECT
          ACAD_CAREER as acad_career,
          TERM_ID as term_id,
          SESSION_CODE as session_code,
          MID_BEGIN_DT as mid_term_begin_date,
          MID_END_DT as mid_term_end_date,
          FINAL_BEGIN_DT as final_begin_date,
          FINAL_END_DT as final_end_date
        FROM
          SISEDO.GRADING_DATES_CS_V00_VW
      SQL
    end

    def self.section_reserved_capacity_count(term_id, section_id)
      safe_query <<-SQL
        SELECT COUNT(*) as reserved_seating_rules_count
        FROM
          SISEDO.CLC_CURRENT_RESERVE_CAPACITYV00_VW
        WHERE
          TERM_ID = '#{term_id}' AND
          CLASS_NBR = '#{section_id}' AND
          RESERVED_SEATS > 0
      SQL
    end

    def self.get_section_reserved_capacity(term_id, section_id)
      safe_query <<-SQL
        SELECT CLASS_NBR as class_nbr,
          CLASS_SECTION as class_section,
          COMPONENT as component,
          CATALOG_NBR as catalog_nbr,
          RESERVED_SEATS as reserved_seats,
          RESERVED_SEATS_TAKEN as reserved_seats_taken,
          REQUIREMENT_GROUP_DESCR as requirement_group_descr,
          TERM_ID as term_id
        FROM
          SISEDO.CLC_CURRENT_RESERVE_CAPACITYV00_VW
        WHERE
          TERM_ID = '#{term_id}' AND
          CLASS_NBR = '#{section_id}'
      SQL
    end

    def self.get_section_capacity(term_id, section_id)
      safe_query <<-SQL
        SELECT
          "enrolledCount" as enrolled_count,
          "waitlistedCount" as waitlisted_count,
          "minEnroll" as min_enroll,
          "maxEnroll" as max_enroll,
          "maxWaitlist" as max_waitlist
        FROM
          SISEDO.CLASSSECTIONALLV01_MVW
        WHERE
          "id" = '#{section_id}' AND
          "term-id" = '#{term_id}'
      SQL
    end

    def self.get_student_term_cpp(student_id)
      result = safe_query <<-SQL
        SELECT
          TERM_ID as term_id,
          ACAD_CAREER_CODE as acad_career,
          ACAD_CAREER_DESCR as acad_career_descr,
          ACAD_PROGRAM as acad_program,
          ACAD_PLAN as acad_plan
        FROM SISEDO.STUDENT_TERM_CPPV00_VW
        WHERE
          INSTITUTION = '#{UC_BERKELEY}' AND
          STUDENT_ID = '#{student_id}'
        ORDER BY TERM_ID DESC
      SQL
      return result
    end

    def self.get_undergrad_terms(oldest_term_id, opts={})
      sql = <<-SQL
        SELECT ACADCAREER_CODE as career_code,
          TERM_ID as term_id,
          TERM_TYPE as term_type,
          TERM_YEAR as term_year,
          TERM_CODE as term_code,
          TERM_DESCR as term_descr,
          TERM_BEGIN_DT as term_begin_date,
          TERM_END_DT as term_end_date,
          CLASS_BEGIN_DT as class_begin_date,
          CLASS_END_DT as class_end_date,
          INSTRUCTION_END_DT as instruction_end_date,
          GRADES_ENTERED_DT as grades_entered_date,
          END_DROP_ADD_DT as end_drop_add_date,
          IS_SUMMER as is_summer
        FROM  SISEDO.CLC_TERMV00_VW
        WHERE INSTITUTION = '#{UC_BERKELEY}' AND
          ACADCAREER_CODE = 'UGRD' AND
          TERM_TYPE IS NOT NULL AND
          TERM_ID >= '#{oldest_term_id}'
        ORDER BY TERM_ID DESC
      SQL
      safe_query(sql, opts)
    end

    def self.search_students(search_string)
      result = safe_query <<-SQL
        SELECT *
        FROM
          (
            SELECT DISTINCT
              STUDENT_ID AS student_id,
              CAMPUS_ID AS campus_uid,
              OPRID AS oprid,
              FIRST_NAME AS first_name_legal,
              MIDDLE_NAME AS middle_name_legal,
              LAST_NAME AS last_name_legal,
              UC_PRF_FIRST_NM AS first_name_preferred,
              UC_PRF_MIDDLE_NM AS middle_name_preferred,
              EMAIL_ADDR AS email,
              ACAD_PROG AS academic_programs
            FROM SISEDO.CLC_STDNT_LOOKUP_V00_VW
            WHERE upper(UC_SRCH_CRIT) LIKE upper('%#{search_string}%')
            AND ((CAMPUS_ID <> ' ' AND CAMPUS_ID IS NOT NULL) OR (OPRID <> ' ' AND OPRID IS NOT NULL))
          )
        WHERE rownum < 31
      SQL
      result
    end

    def self.get_exam_results(student_id)
      result = safe_query <<-SQL
        SELECT TEST_ID AS id,
          TEST_DESCRIPTION AS descr,
          TEST_SCORE AS score,
          TEST_DATE AS taken
        FROM SISEDO.CLC_SR_TEST_RSLTV00_VW
        WHERE STUDENT_ID = '#{student_id}'
      SQL
      result
    end

    def self.has_exam_results?(student_id)
      result = safe_query <<-SQL
        SELECT TEST_ID
        FROM SISEDO.CLC_SR_TEST_RSLTV00_VW
        WHERE STUDENT_ID = '#{student_id}' AND
        rownum = 1
      SQL
      result.any?
    end

    def self.get_pnp_calculator_values(student_id)
      result = safe_query <<-SQL
        SELECT TOTAL_GPA_UNITS,
          TOTAL_NOGPA_UNITS as total_no_gpa_units,
          TOTAL_TRANSFER_UNITS,
          MAX_RATIO_BASE_UNITS,
          GPA_RATIO_UNITS,
          NOGPA_RATIO_UNITS as no_gpa_ratio_units,
          PNP_RATIO
        FROM SISEDO.CLC_PNP_RATIOV00_VW
        WHERE STUDENT_ID = '#{student_id}'
      SQL
      result.first
    end

    def self.omit_drops_and_withdrawals
      # Our H2 test db can't handle the fancy CASE join below.
      if Settings.edodb.adapter == 'h2'
        <<-SQL
          enroll.STDNT_ENRL_STATUS_CODE != 'D' AND
          enroll.GRADE_MARK != 'W'
        SQL
      # Late withdrawals are only indicated in primary section enrollments, and do not change
      # any values in secondary section enrollment rows. The CASE clause implements a
      # conditional join for secondary sections.
      else
        <<-SQL
          enroll.STDNT_ENRL_STATUS_CODE != 'D' AND
          CASE enroll.GRADING_BASIS_CODE WHEN 'NON' THEN (
          SELECT DISTINCT prim_enr.GRADE_MARK
            FROM SISEDO.CLASSSECTIONALLV01_MVW sec
            LEFT JOIN SISEDO.ETS_ENROLLMENTV01_VW prim_enr
              ON prim_enr.CLASS_SECTION_ID = sec."primaryAssociatedSectionId"
              AND prim_enr.TERM_ID = enroll.TERM_ID
              AND prim_enr.STUDENT_ID = enroll.STUDENT_ID
              AND prim_enr.STDNT_ENRL_STATUS_CODE != 'D'
            WHERE sec."id" = enroll.CLASS_SECTION_ID
              AND sec."term-id" = enroll.TERM_ID
              AND prim_enr.STUDENT_ID IS NOT NULL
          )
          ELSE enroll.GRADE_MARK END != 'W'
        SQL
      end
    end
  end
end
