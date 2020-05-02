#!/bin/bash
# Valid and working as of 04/21/2014
# Xcode 5.0.1, XCode Server
#

USERNAME="Your-Company-Name"
APP_NAME="Your-Application-Name"
API_TOKEN="Your-API-Token"

NOTIFY=true
# false - Do not notify, true - Notify users by e-mail
MANDATORY=false
# false - No, true - Yes
DESTINATIONS="[{\"name\": \"Testers\"},{\"name\": \"Beta\"}]"
# "[{\"name\": \"Testers\"}]" - name
# "[{\"id\": \"30a34059-839b-418d-a6cd-d8dce3fb1d64\"}]" - id
# "[{\"name\": \"Testers\"},{\"name\": \"Beta\"}]" - two destination groups

# DO NOT EDIT BELOW HERE!
########################################

# MS Appstore headers
HEADERS=( "Content-Type: application/json" "Accept: application/json" "X-API-Token: $API_TOKEN")

# Parse values from JSON. Usage: parse_JSON RETURN_VAR "$JSON_STRING" ($INT, $STRING, ... - which element to return)
parse_JSON () {

    PARSE_STRING=""
    for var in "${@:3}"
    do
        [ "$var" -ge 0 ] 2>/dev/null && PARSE_STRING+="[$var]" || PARSE_STRING+="[\"$var\"]"
    done

    RESPONSE=$(python3 -c "import sys, json; true = True; false = False; print($2$PARSE_STRING)") || { echo -e "$PARSE_STRING cannot be parsed. JSON: \n$2"; exit 1; }
    eval "$1='$RESPONSE'"
}

uploadToAppCenter () {

    # https://docs.microsoft.com/en-us/appcenter/distribution/uploading
    # Create an upload resource and get an upload_url (good for 24 hours)
    JSON=$(
    /usr/bin/curl \
    --http1.1 \
    -X POST \
    "${HEADERS[@]/#/-H}" \
    "https://api.appcenter.ms/v0.1/apps/$USERNAME/$APP_NAME/release_uploads"
    ) || { echo "Create an upload resource failed. Server response: $JSON"; return 1; }

    parse_JSON UPLOAD_ID "$JSON" "upload_id"
    parse_JSON UPLOAD_URL "$JSON" "upload_url"


    # Copy the upload_url (will be a rink.hockeyapp.net URL) from the response in the previous step, and also save the upload_id for the step after this one. Upload to upload_url using a POST request. Use multipart/form-data as the Content-Type, where the key is ipa (key is always IPA even when uploading Android APKs) and the value is @/path/to/your/build.ipa.
    JSON=$(
    /usr/bin/curl \
    --http1.1 \
    -F ipa=@"${APP_PRODUCT}" \
    $UPLOAD_URL
    ) || { echo "IPA Upload failed. Server response: $RESPONSE"; return 1; } 


    # After the upload has finished, update upload resource's status to committed and get a release_url, save that for the next step — PATCH /v0.1/apps/{owner_name}/{app_name}/release_uploads/{upload_id}
    JSON=$(
    /usr/bin/curl \
    --http1.1 \
    -X PATCH \
    "${HEADERS[@]/#/-H}" \
    -d '{ "status": "committed"  }' \
    "https://api.appcenter.ms/v0.1/apps/$USERNAME/$APP_NAME/release_uploads/$UPLOAD_ID"
    ) || { echo "Update upload resource's status to committed failed. Server response: $RESPONSE"; return 1; } 

    parse_JSON RELEASE_URL "$JSON" "release_url"


    # Distribute the uploaded release to destinations using testers, groups, or stores. This is nessesary to view uploaded releases in the developer portal. POST /v0.1/apps/{owner_name}/{app_name}/releases/{release_id}/testers, POST /v0.1/apps/{owner_name}/{app_name}/releases/{release_id}/groups, POST /v0.1/apps/{owner_name}/{app_name}/releases/{release_id}/stores
    JSON=$(
    /usr/bin/curl \
    -X PATCH \
    "${HEADERS[@]/#/-H}" \
    -d "{ \"destinations\": ${DESTINATIONS}, \"release_notes\": \"${RELEASE_NOTES}\", \"mandatory_update\": $MANDATORY, \"notify_testers\": $NOTIFY  }" \
    "https://api.appcenter.ms/$RELEASE_URL"
    ) || { echo "Distribute the uploaded release to destinations failed. Server response: $RESPONSE"; return 1; }


    # Create an DSYM upload resource and get an upload_url (good for 24 hours)"
    JSON=$(
    /usr/bin/curl \
    -X POST \
    "${HEADERS[@]/#/-H}" \
    -d '{"symbol_type": "Apple"}' \
    "https://api.appcenter.ms/v0.1/apps/$USERNAME/$APP_NAME/symbol_uploads"
    ) || { echo "Create an DSYM upload resource failed. Server response: $RESPONSE"; return 1; }

    parse_JSON UPLOAD_ID "$JSON" "symbol_upload_id"
    parse_JSON UPLOAD_URL "$JSON" "upload_url"


    # Upload Symbols to upload_url using a PUT request."
    JSON=$(
    /usr/bin/curl --http1.1 \
    -X PUT \
    --header 'x-ms-blob-type: BlockBlob' \
    --upload-file "${XCS_PRODUCT}.dSYM.zip" \
    "$UPLOAD_URL"
    ) || { echo "Upload Symbols failed. Server response: $RESPONSE"; return 1; }


    # Commits or aborts the symbol upload process for a new set of symbols for the specified application
    JSON=$(
    /usr/bin/curl \
    -X PATCH \
    "${HEADERS[@]/#/-H}" \
    -d '{ "status": "committed" }' \
    "https://api.appcenter.ms/v0.1/apps/$USERNAME/$APP_NAME/symbol_uploads/$UPLOAD_ID"
    ) || { echo "Commit the symbol upload process failed. Server response: $RESPONSE"; return 1; }

    echo "Appcenter Upload Finished!"
true
}


# Get last build number & date
echo "Getting latest build number"

JSON=$(/usr/bin/curl -X GET "${HEADERS[@]/#/-H}" "https://api.appcenter.ms/v0.1/apps/$USERNAME/$APP_NAME/recent_releases")
[ ! $? -eq "0" ] && { echo "Can't get last build number. Server response: $RESPONSE"; exit 1; } 

parse_JSON LAST_BUILD_NUMBER "$JSON" 0 "version"
parse_JSON LAST_BUILD_DATE "$JSON" 0 "uploaded_at"


# Get this build number
CURRENT_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "${XCS_ARCHIVE}/Info.plist")

# Check if this build is newer
[ "$CURRENT_BUILD_NUMBER" = "$LAST_BUILD_NUMBER" ] && { echo "This Build already released"; exit 0; }

# Get Change log from last build date
RELEASE_NOTES=$(git --git-dir "${XCS_PRIMARY_REPO_DIR}//.git" log --no-merges --since=$LAST_BUILD_DATE --pretty=tformat:'%s - %cn %h \n' -z | tr -d '"')

# Check if Release notes are empty and limit to max 5k symbols for Appcenter
RELEASE_NOTES=$([ ${#RELEASE_NOTES} -gt 5000 ] \
    && echo ${RELEASE_NOTES:0:4997}"..." \
    || { [ "$RELEASE_NOTES" != "" ] \
        && echo "$RELEASE_NOTES" \
        || echo "No changes since last build.";} )


# Zipping dSYM and .app
echo "Zipping .dSYM and .app"

filename="$(basename "${XCS_PRODUCT}")"

if [ "${filename##*.}" = "ipa" ]; then
    APP_PRODUCT="${XCS_PRODUCT}"
else
    cd "$( dirname "${XCS_PRODUCT}")" || exit 1
    /usr/bin/zip -r -y "${XCS_PRODUCT}.zip" -- *.app
    APP_PRODUCT="${XCS_PRODUCT}.zip"
fi

/usr/bin/zip -x .DS_Store -ry "${XCS_PRODUCT}.dSYM.zip" "${XCS_ARCHIVE}/dSYMs/" 

echo "Created .dSYM and .app for ${XCS_PRODUCT}"

# Upload to Appcenter
uploadToAppCenter && say "${XCS_BOT_NAME} Great Success" || say "${XCS_BOT_NAME} Fail"


# Remove .dSYM and .app zips
rm -rf "${XCS_PRODUCT}.zip" "${XCS_PRODUCT}.dSYM.zip"