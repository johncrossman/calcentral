# Canvas support

## Canvas maintenance Rake tasks

* `RAILS_ENV=production bundle exec rake canvas:full_refresh`
    1. Request Canvas reports for all user accounts, and all course sections for every current term.
    2. Download the reports.
    3. Check all existing user accounts against campus data, change their SIS IDs as needed, and append any other account changes to a "users" CSV file.
    4. Append each section's current student enrollments and official list of instructors to a term-specific "enrollments" CSV file.
    5. Add any new student or instructor accounts to the "users" CSV file.
    6. Upload the "users" CSV file to Canvas.
    7. Upload each term's "enrollments" CSV to Canvas as a batch update, replacing all the previously imported student and instructor assignments for the term.
* `RAILS_ENV=production bundle exec rake canvas:repair_course_sis_ids TERM_ID='TERM:2013-C'`

    Our current integration scheme links a Canvas Course Section's SIS ID to the ID of an official section in campus systems. E.g., a Canvas Section whose sis_id was `SEC:2013-C-7309` would draw enrollments and instructors from CCN 7309 Summer 2013. For imports to work, the section's Canvas Course must have _some_ SIS ID, but what it is doesn't matter (for now). This task is an administrative convenience so that we don't manually have to come up with Course SIS IDs.
    1. Request a Canvas report on the sections of the specified term.
    2. Download the report.
    3. For each Course which has an SIS-integrated Section, but which has no SIS ID (or an otherwise improper SIS ID), write a good SIS ID to the Course.

## Canvas maintenance shell scripts

* `script/configure-all-canvas-apps-from-current-host.sh`

    Checks the integrated bCourses site's external app configurations, and resets them as needed to match
    the external apps configuration defined in CalCentral/Junction. This is used to:
    * Reset Beta and Test bCourses sites after their data has been overwritten by Instructure.
    * Add new Junction-hosted LTI apps.
    * Modify the name, default visibility, or other properties of existing Junction-hosted LTI apps.
    * Set new LTI secrets for the apps.
* `script/refresh-canvas-enrollments.sh`

    Runs `rake canvas:full_refresh` with `RAILS_ENV=production`.

## Canvas embedded tools

* XML configuration for Rosters app
Sets the app to show up as a Course site tool, visible to teachers and admins, and sending parameters to describe the current user and site context. Generated by [Instructure's XML Config builder](http://www.edu-apps.org/build_xml.html):

```
<?xml version="1.0" encoding="UTF-8"?>
<cartridge_basiclti_link xmlns="http://www.imsglobal.org/xsd/imslticc_v1p0"
    xmlns:blti = "http://www.imsglobal.org/xsd/imsbasiclti_v1p0"
    xmlns:lticm ="http://www.imsglobal.org/xsd/imslticm_v1p0"
    xmlns:lticp ="http://www.imsglobal.org/xsd/imslticp_v1p0"
    xmlns:xsi = "http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation = "http://www.imsglobal.org/xsd/imslticc_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticc_v1p0.xsd
    http://www.imsglobal.org/xsd/imsbasiclti_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imsbasiclti_v1p0.xsd
    http://www.imsglobal.org/xsd/imslticm_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticm_v1p0.xsd
    http://www.imsglobal.org/xsd/imslticp_v1p0 http://www.imsglobal.org/xsd/lti/ltiv1p0/imslticp_v1p0.xsd">
    <blti:title>Roster Photos</blti:title>
    <blti:description>Browse and search official roster photos</blti:description>
    <blti:icon></blti:icon>
    <blti:launch_url>http://localhost:3000/canvas/embedded/rosters</blti:launch_url>
    <blti:extensions platform="canvas.instructure.com">
      <lticm:property name="tool_id">calcentral_rosters</lticm:property>
      <lticm:property name="privacy_level">public</lticm:property>
      <lticm:options name="course_navigation">
        <lticm:property name="url">http://localhost:3000/canvas/embedded/rosters</lticm:property>
        <lticm:property name="text">Roster Photos</lticm:property>
        <lticm:property name="visibility">admins</lticm:property>
        <lticm:property name="default">enabled</lticm:property>
        <lticm:property name="enabled">true</lticm:property>
      </lticm:options>
    </blti:extensions>
    <cartridge_bundle identifierref="BLTI001_Bundle"/>
    <cartridge_icon identifierref="BLTI001_Icon"/>
</cartridge_basiclti_link>
```

### Dependencies

Canvas is configured on the account level to include [Javascript](../public/canvas/canvas-customization.js) and [CSS](../public/canvas/canvas-skin.css) from the CalCentral server. Some modifications to the Canvas user interface are being made by the Javascript included within Canvas. Please note the following:

* A modification is made to the '+ People' button displayed on the 'People' section within a Canvas course site. This button triggers the content of the popup window that is displayed to be replaced with bCourses specific instructions, including a  link to the 'Find a Person to Add' LTI application. This [modification](../public/canvas/canvas-customization.js#L9) relies on the public [CanvasController#external_tools](../app/controllers/canvas_controller.rb#L16) API end-point to obtain the LTI application ID for the 'Find a Person to Add' LTI application within the cloud hosted Canvas system.
* A [modification](../public/canvas/canvas-customization.js#L69) is made to the Canvas Dashboard page, and Course index page, which inserts a 'Create a Course Site' button in the main content area, aligned to the right. This modification also relies on the Canvas external tools API end-point to generate the URL for the 'Create a Course Site' LTI application.

