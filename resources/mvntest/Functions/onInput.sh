functions=$(find_resource_variable "%%context.resourceName%%" functions)

export disableArtifactoryPublisher="-Dartifactory.publish.artifacts=false -Dartifactory.publish.buildInfo=false"
export disableArtifactoryRecorder="-Dorg.jfrog.build.extractor.maven.recorder.activate=false $disableArtifactoryPublisher"

get_jfrog_version() {
  if [ -z "$CLI_MAJOR_VERSION" ]; then
    export CLI_MAJOR_VERSION=$(jfrog --version | awk '{print $3}' | cut -d '.' -f 1) #Hi
  fi
  echo "$CLI_MAJOR_VERSION"
}
export -f get_jfrog_version

use_branch_specific_dependency_version() {
  local versionProperty="$1"
  local pipelineName="$2"
  local sourceBranch="$3"
  local module="$4"

  if [[ "$sourceBranch" != "master" ]]; then
    local versionValue=$(get_maven_project_property "$versionProperty" "$module")
    if [[ "$versionValue" == *-SNAPSHOT ]]; then
      local UUID=$(get_uuid)
      local output_file="${step_tmp_dir}/${UUID}.json"
      get_pipeline_info $output_file $pipelineName $sourceBranch
      if [ "$?" != 0 ]; then
        return 1
      fi
      if [ ! -f "$output_file" ]; then
        echo "pipeline info file is empty"
        return 1
      fi
      local pipelineCount=$(jq '. | length' $output_file)
      if [[ "$pipelineCount" -gt 0 ]]; then
        local branchVersion="${versionValue/-SNAPSHOT/-${sourceBranch}-SNAPSHOT}"
        echo "Using branch version ${branchVersion} for $versionProperty"
        add_run_variables maven_config="-D${versionProperty}=${branchVersion} ${maven_config}"
      else
        echo "Skipping branch versioning, no pipeline for branch $sourceBranch"
      fi
    else
      echo "Skipping branch versioning for released version $versionValue"
    fi
  else
    echo "Skipping branch specific versioning for master"
  fi
}
export -f use_branch_specific_dependency_version

get_pipeline_info() {
  local output_file="$1"
  local pipelineName="$2"
  local sourceBranch="$3"

  local curl_opts=""
  if [ "$no_verify_ssl" == "true" ]; then
    curl_opts="--insecure"
  fi
  echo "Fetching pipelines URL"
  local get_pipelines_url_cmd="curl \
    -s -S \
    -H 'Content-Type: application/json; charset=utf-8' \
    -H 'Authorization: Bearer $builder_api_token' \
    -H 'jfrog-pipelines-session-id: $JFROG_PIPELINES_SESSION_ID' \
    -o $output_file \
    -w \"%{http_code}\" \
    -XGET '${pipelines_api_url}/pipelines?light=true&names=${pipelineName}&pipelineSourceBranches=${sourceBranch}' \
    $curl_opts"
  local status_code=$(eval "$get_pipelines_url_cmd")
  if [ "$status_code" == "200" ]; then
    echo "Successfully fetched pipeline information"
  else
    echo "Failed to fetch pipeline information with $status_code"
    if [ $status_code -gt 500 ]; then
      cat $output_file
    fi
    rm -f $output_file
    return 1
  fi
}
export -f get_pipeline_info

configure_mvn() {
  local mvnConfigOptions=""

  for arg in "$@"
  do
    case "$arg" in
      resolve)
        local resolverSnapshotRepo=$(find_step_configuration_value "resolverSnapshotRepo")
        local resolverReleaseRepo=$(find_step_configuration_value "resolverReleaseRepo")
        if [ -z "$resolverSnapshotRepo" ]; then
          resolverSnapshotRepo="$resolverReleaseRepo"
        fi

        if [ ! -z "$resolverSnapshotRepo" ] && [ ! -z "$resolverReleaseRepo" ]; then
          mvnConfigOptions+=" --server-id-resolve $artifactoryIntegrationName"
          mvnConfigOptions+=" --repo-resolve-snapshots '$resolverSnapshotRepo'"
          mvnConfigOptions+=" --repo-resolve-releases '$resolverReleaseRepo'"
        fi
        ;;
      deploy)
        local deployerSnapshotRepo=$(find_step_configuration_value "deployerSnapshotRepo")
        local deployerReleaseRepo=$(find_step_configuration_value "deployerReleaseRepo")

        if [ ! -z "$deployerSnapshotRepo" ] && [ ! -z "$deployerReleaseRepo" ]; then
          mvnConfigOptions+=" --server-id-deploy $artifactoryIntegrationName"
          mvnConfigOptions+=" --repo-deploy-snapshots '$deployerSnapshotRepo'"
          mvnConfigOptions+=" --repo-deploy-releases '$deployerReleaseRepo'"
        fi
        ;;
    esac
  done

  if [ ! -z "$mvnConfigOptions" ]; then
    local cli_major_version=$(get_jfrog_version)
    if [ $cli_major_version -lt 2 ]; then
      execute_command "retry_command jfrog rt mvn-config $mvnConfigOptions"
    else
      execute_command "retry_command jfrog mvn-config $mvnConfigOptions"
    fi
  fi
}
export -f configure_mvn

execute_mvn() {
  local quiet=false
  if [ "$1" == "--quiet" ]; then
    quiet=true
    shift
  fi

  local cli_major_version=$(get_jfrog_version)
  local command=""
  if [ $cli_major_version -lt 2 ]; then
    command="jfrog rt mvn $@"
  else
    command="jfrog mvn $@"
  fi
  if [[ "$command" == *"install"* ]] && [[ "$command" != *"$disableArtifactoryPublisher"* ]]; then
    command="$command $disableArtifactoryPublisher"
  fi

  if [ "$quiet" == "true" ]; then
    local OLDJFROG_CLI_LOG_LEVEL="${JFROG_CLI_LOG_LEVEL}"
    export JFROG_CLI_LOG_LEVEL="ERROR"
    eval "$command"
    export JFROG_CLI_LOG_LEVEL="${JFROG_CLI_LOG_LEVEL}"
  else
    execute_command "$command"
  fi
}
export -f execute_mvn

retry_mvn() {
  for i in $(seq 1 3);
    do
      {
        execute_mvn "$@"
        ret=$?
        [ $ret -eq 0 ] && break;
      } || {
        echo "retrying $i of 3 times..." >&2
      }
    done
    return $ret
}
export -f retry_mvn

get_maven_project_version() {
  echo $(get_maven_project_property "project.version" "$1")
}
export -f get_maven_project_version

get_maven_project_property() {
  local property="$1"
  local module="$2"
  if [[ ! -z "$module" ]]; then
    if [[ "$module" == :* ]]; then
      module="-pl $module"
    else
      module="-N -f $module"
    fi
  fi
  local fileName=$(get_uuid)
  execute_mvn --quiet "-q $module help:evaluate -Dexpression=$property -DforceStdout -Doutput=$step_tmp_dir/$fileName $disableArtifactoryRecorder"
  local value="$(cat $step_tmp_dir/$fileName)"
  rm $step_tmp_dir/$fileName
  echo "$value"
}
export -f get_maven_project_property

set_maven_project_version() {
  arguments="-N versions:set -DnewVersion=$1 -DgenerateBackupPoms=false"
  if [ -n "$2" ]
  then
    arguments+=" versions:set-property -Dproperty=$2"
  fi
  execute_mvn "$arguments $disableArtifactoryRecorder"
}

cleanup_run_files() {
  local cache_name="$1"

  local UUID=$(get_uuid)
  local temp_dir="$step_tmp_dir/$UUID"
  mkdir -p $temp_dir/state
  local artifact_url_output_file="$temp_dir/get_run_state_location.json"
  local del_output_file="$temp_dir/del_output.json"
  get_run_state_location $artifact_url_output_file
  if [ "$?" != 0 ]; then
    return 1
  fi
  if [ ! -f "$artifact_url_output_file" ]; then
    echo "Run artifact url file is empty"
    return 1
  fi
  local artifactory_url=$(jq -r '.fileStoreProviderUrl' $artifact_url_output_file)
  local token=$(jq -r '.token' $artifact_url_output_file)
  local relative_path=$(jq -r '.relativePath' $artifact_url_output_file)
  rm -f $artifact_url_output_file
  if [ -z $artifactory_url ]; then
    echo "Unable to obtain URL to download state"
    return 1
  elif [ -z $token ]; then
    echo "Unable to obtain token to download state"
    return 1
  elif [ -z $relative_path ]; then
    echo "Missing state location"
    return 1
  fi

  configure_jfrog_cli --artifactory-url $artifactory_url --access-token $token --server-name $UUID
  retry_command jfrog rt del --insecure-tls=${no_verify_ssl} --server-id $UUID "${relative_path}state/${cache_name}" > "$del_output_file"
  cleanup_jfrog_cli --server-name $UUID

  echo "Deleted ${relative_path}state/${cache_name}"
  rm -rf $temp_dir
}
export -f cleanup_run_files

promote_run_files() {
  if [ "$1" == "" ] || [ "$2" == "" ]; then
      echo "Usage: promote_run_files NAME TARGET_REPOSITORY" >&2
      exit 1
    fi
  local cache_name="$1"
  local promotion_path="$2"

  local UUID=$(get_uuid)
  local temp_dir="$step_tmp_dir/$UUID"
  mkdir -p $temp_dir/state
  local artifact_url_output_file="$temp_dir/get_run_state_location.json"
  local copy_output_file="$temp_dir/copy_output.json"
  get_run_state_location $artifact_url_output_file
  if [ "$?" != 0 ]; then
    return 1
  fi
  if [ ! -f "$artifact_url_output_file" ]; then
    echo "Run artifact url file is empty"
    return 1
  fi
  local artifactory_url=$(jq -r '.fileStoreProviderUrl' $artifact_url_output_file)
  local token=$(jq -r '.token' $artifact_url_output_file)
  local relative_path=$(jq -r '.relativePath' $artifact_url_output_file)
  rm -f $artifact_url_output_file
  if [ -z $artifactory_url ]; then
    echo "Unable to obtain URL to download state"
    return 1
  elif [ -z $token ]; then
    echo "Unable to obtain token to download state"
    return 1
  elif [ -z $relative_path ]; then
    echo "Missing state location"
    return 1
  fi

  configure_jfrog_cli --artifactory-url $artifactory_url --access-token $token --server-name $UUID
  retry_command jfrog rt mv --insecure-tls=${no_verify_ssl} --server-id $UUID --flat=true "${relative_path}state/${cache_name}" "${promotion_path}" > "$copy_output_file"
  cleanup_jfrog_cli --server-name $UUID

  echo "Promoted ${relative_path}state/${cache_name}"
  rm -rf $temp_dir
}
export -f promote_run_files;

run_file_sha1() {
  if [ "$1" == "" ]; then
      echo "Usage: run_file_sha1 NAME" >&2
      exit 1
    fi
  local cache_name="$1"

  local UUID=$(get_uuid)
  local temp_dir="$step_tmp_dir/$UUID"
  mkdir -p $temp_dir/state
  local artifact_url_output_file="$temp_dir/get_run_state_location.json"
  local search_output_file="$temp_dir/search_output.json"
  local log=$(get_run_state_location $artifact_url_output_file)
  if [ "$?" != 0 ]; then
    echo "$log"
    return 1
  fi
  if [ ! -f "$artifact_url_output_file" ]; then
    echo "Run artifact url file is empty"
    return 1
  fi
  local artifactory_url=$(jq -r '.fileStoreProviderUrl' $artifact_url_output_file)
  local token=$(jq -r '.token' $artifact_url_output_file)
  local relative_path=$(jq -r '.relativePath' $artifact_url_output_file)
  rm -f $artifact_url_output_file
  if [ -z $artifactory_url ]; then
    echo "Unable to obtain URL to download state"
    return 1
  elif [ -z $token ]; then
    echo "Unable to obtain token to download state"
    return 1
  elif [ -z $relative_path ]; then
    echo "Missing state location"
    return 1
  fi

  log=$(configure_jfrog_cli --artifactory-url $artifactory_url --access-token $token --server-name $UUID)
  if [ "$?" != 0 ]; then
    echo "$log"
    return 1
  fi
  log=$(retry_command jfrog rt s --insecure-tls=${no_verify_ssl} --server-id $UUID "${relative_path}state/${cache_name}" > "$search_output_file")
  if [ "$?" != 0 ]; then
    echo "$log"
    return 1
  fi
  log=$(cleanup_jfrog_cli --server-name $UUID)
  if [ "$?" != 0 ]; then
    echo "$log"
    return 1
  fi

  local sha1=$(jq -r '.[].sha1' $search_output_file)
  rm -rf $temp_dir
  echo "$sha1"
}
export -f run_file_sha1;

get_run_state_relative_path() {
  local artifact_url_output_file="$step_tmp_dir/get_run_state_location.json"
  local log=$(get_run_state_location $artifact_url_output_file)
  if [ "$?" != 0 ]; then
    echo "$log"
    return 1
  fi
  if [ ! -f "$artifact_url_output_file" ]; then
    echo "$log"
    echo "Run artifact url file is empty"
    return 1
  fi
  local relative_path=$(jq -r '.relativePath' $artifact_url_output_file)
  rm $artifact_url_output_file

  echo "${relative_path}state/"
}
export -f get_run_state_relative_path

if [[ "${functions}" != *"+add_run_files"* ]]; then
  # Remove the old add_run_files implementation to create a better one
  unset add_run_files
  add_run_files() {
    if [ "$1" == "" ] || [ "$2" == "" ]; then
      echo "Usage: add_run_files [DIRECTORY] [FILE] NAME" >&2
      exit 1
    fi
    # Wildcards will be expanded.  The last item is the name.
    local source_files=( "$@" )
    local cache_name="${!#}"
    unset "source_files[${#source_files[@]}-1]"
    local pattern=" |'"
    if [[ $cache_name =~ $pattern ]]; then
      echo "Name may not contain spaces."
      exit 1
    fi
    if [[ "$cache_name" == "run.env" ]]; then
      echo "The name may not be run.env."
      exit 1
    fi
    if [[ "$cache_name" == "." ]]; then
      echo "Usage: add_run_files [DIRECTORY] [FILE] NAME" >&2
      echo "\".\" is not a valid name." >&2
      exit 1
    fi
    if [[ "$cache_name" == ".." ]]; then
      echo "Usage: add_run_files [DIRECTORY] [FILE] NAME" >&2
      echo "\"..\" is not a valid name." >&2
      exit 1
    fi
    local UUID=$(get_uuid)
    echo "Copying files to state the new way"
    local temp_dir="$step_tmp_dir/$UUID"
    local output_directory="$temp_dir/files"
    if [ -e "$temp_dir" ]; then
      rm -r "$temp_dir"
    fi
    if [ "${#source_files[@]}" -gt 1 ]; then
      mkdir -p "$output_directory/$cache_name"
      for filepath in "${source_files[@]}"; do
        cp -r "$filepath" "$output_directory/$cache_name/$filepath"
      done
    else
      mkdir -p "$output_directory"
      cp -r "$source_files" "$output_directory/$cache_name"
    fi
    echo "Uploading files to run state"

    mkdir -p $temp_dir/state
    local artifact_url_output_file="$temp_dir/get_run_state_location.json"
    local search_output_file="$temp_dir/search_output.json"
    get_run_state_location $artifact_url_output_file
    if [ "$?" != 0 ]; then
     return 1
    fi
    if [ ! -f "$artifact_url_output_file" ]; then
     echo "Run artifact url file is empty"
     return 1
    fi
    local artifactory_url=$(jq -r '.fileStoreProviderUrl' $artifact_url_output_file)
    local token=$(jq -r '.token' $artifact_url_output_file)
    local relative_path=$(jq -r '.relativePath' $artifact_url_output_file)
    rm -f $artifact_url_output_file
    if [ -z $artifactory_url ]; then
     echo "Unable to obtain URL to download state"
     return 1
    elif [ -z $token ]; then
     echo "Unable to obtain token to download state"
     return 1
    elif [ -z $relative_path ]; then
     echo "Missing state location"
     return 1
    fi

    echo "Uploading run files to $artifactory_url $relative_path"
    local detailedSummaryFile="${temp_dir}/detailedSummaryFile.json"
    configure_jfrog_cli --artifactory-url $artifactory_url --access-token $token --server-name $UUID
    jfrog rt u --server-id $UUID --insecure-tls=${no_verify_ssl} --detailed-summary=true "$output_directory/$cache_name" "${relative_path}state/${cache_name}" > "$detailedSummaryFile"
    #save_artifact_info file $detailedSummaryFile --build-name $JFROG_CLI_BUILD_NAME --build-number $JFROG_CLI_BUILD_NUMBER
    cleanup_jfrog_cli --server-name $UUID

    echo "Files saved"
    cat $detailedSummaryFile
    rm -rf $temp_dir
  }
  export -f add_run_files
fi

if [[ "${functions}" != *"+restore_run_files"* ]]; then
  # Remove the old restore_run_files implementation to create a better one
  unset restore_run_files
  restore_run_files() {
    if [ "$1" == "" ] || [ "$2" == "" ]; then
      echo "Usage: restore_run_files NAME PATH" >&2
      exit 1
    fi
    local cache_name="$1"
    local restore_path="$2"
    local cache_location="$step_tmp_dir/caches/$cache_name"
    local pattern=" |'"
    if [[ $cache_name =~ $pattern ]]; then
      echo "Name may not contain spaces."
      exit 1
    fi
    if [ -d $cache_location ] || [ -f $cache_location ]; then
      echo "State already downloaded for $cache_name at $cache_location."
    else
      local UUID=$(get_uuid)
      local temp_dir="$step_tmp_dir/$UUID"
      mkdir -p $temp_dir/state
      local artifact_url_output_file="$temp_dir/get_run_state_location.json"
      local search_output_file="$temp_dir/search_output.json"
      get_run_state_location $artifact_url_output_file
      if [ "$?" != 0 ]; then
        return 1
      fi
      if [ ! -f "$artifact_url_output_file" ]; then
        echo "Run artifact url file is empty"
        return 1
      fi
      local artifactory_url=$(jq -r '.fileStoreProviderUrl' $artifact_url_output_file)
      local token=$(jq -r '.token' $artifact_url_output_file)
      local relative_path=$(jq -r '.relativePath' $artifact_url_output_file)
      rm -f $artifact_url_output_file
      if [ -z $artifactory_url ]; then
        echo "Unable to obtain URL to download state"
        return 1
      elif [ -z $token ]; then
        echo "Unable to obtain token to download state"
        return 1
      elif [ -z $relative_path ]; then
        echo "Missing state location"
        return 1
      fi
      configure_jfrog_cli --artifactory-url $artifactory_url --access-token $token --server-name $UUID
      retry_command jfrog rt search --insecure-tls=${no_verify_ssl} --include-dirs=true --server-id $UUID "${relative_path}state/${cache_name}" > "$search_output_file"
      local artifact_type=$(jq -r '.[0].type' "$search_output_file")
      if [ "$artifact_type" == "file" ]; then
        retry_command jfrog rt download --flat=true --insecure-tls=${no_verify_ssl} --include-dirs=true --server-id $UUID "${relative_path}state/${cache_name}" "$cache_location"
      elif [ "$artifact_type" == "folder" ]; then
        retry_command jfrog rt download --insecure-tls=${no_verify_ssl} --include-dirs=true --server-id $UUID "${relative_path}state/${cache_name}/*" "$temp_dir/state/"
        cp -r -p $temp_dir/state/${relative_path#*/}state/${cache_name} $cache_location
      fi
      rm -rf $temp_dir
      cleanup_jfrog_cli --server-name $UUID
    fi
    if [ ! -d "$cache_location" ] && [ ! -f "$cache_location" ]; then
      echo "No state found for $cache_name at $cache_location."
      ls -l "$step_tmp_dir/caches/" || true
      return 0
    fi
    echo "Restoring state files"
    if [ -d "$cache_location" ]; then
      mkdir -p "$restore_path"
      cp -r "$cache_location/." "$restore_path"
    elif [ -f "$cache_location" ]; then
      mkdir -p "$(dirname $cache_location)"
      cp "$cache_location" "$restore_path"
    fi
    echo "Files restored to $restore_path"
  }
  export -f restore_run_files
fi
