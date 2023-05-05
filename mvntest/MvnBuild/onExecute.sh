# Copied MvnBuild from the MvnBuild native step of Jfrog Pipelines, see stepletScript.sh generated for a build step.
MvnBuild() {
  artifactoryIntegrationName=$(get_integration_name --type Artifactory)
  outputBuildInfoResourceName=$(get_resource_name --type BuildInfo --operation OUT)

  inputGitRepoResourceName=""
  local gitRepoResources=$(get_resource_names --type GitRepo --operation IN)
  if [ $step_configuration_inputResources_len -gt 0 ]; then
    for (( c=0; c<$step_configuration_inputResources_len; c++ )); do
      local inputResourceName=$(eval echo "$"step_configuration_inputResources_"$c"_name)
      local gitRepoResource=$(echo "$gitRepoResources" | jq --raw-output ".[]|select(. == \"${inputResourceName}\")")
      if [ "$inputResourceName" == "$gitRepoResource" ]; then
        inputGitRepoResourceName="$inputResourceName"
        break
      fi
    done
  fi
  if [ -z "$inputGitRepoResourceName" ]; then
    execute_command "echo 'No GitRepo resource found'"
    return 1
  fi

  execute_command "jfrog --version"
  execute_command "use_jfrog_cli $artifactoryIntegrationName"
  execute_command "jfrog plugin install ext-build-info"
  local cli_major_version=$(get_jfrog_version)
  sourceLocation=$(find_step_configuration_value "sourceLocation")
  configFileLocation=$(find_step_configuration_value "configFileLocation")
  configFileName=$(find_step_configuration_value "configFileName")
  mvnCommand=$(find_step_configuration_value "mvnCommand")
  scan=$(find_step_configuration_value "forceXrayScan")
  failOnScan=$(find_step_configuration_value "failOnScan")
  publish=$(find_step_configuration_value "autoPublishBuildInfo")
  autoRetry=$(find_step_configuration_value "autoRetry")
  local buildPublishOutputFile="$step_tmp_dir/buildPublishOutput.json"
  if [ -z "$sourceLocation" ]; then
    sourceLocation="."
  fi
  restoreLocalRepositoryCache=$(find_step_configuration_value "restoreLocalRepositoryCache")
  restoreTargetCache=$(find_step_configuration_value "restoreTargetCache")
  mavenConfig=$(find_step_configuration_value "mavenConfig")
  if [ -z "$mavenConfig" ]; then
    mavenConfig="-ntp -fae"
  fi

  if [ ! -z "$restoreLocalRepositoryCache" ]; then
    local repo_cache_file="$step_tmp_dir/${restoreLocalRepositoryCache}_mvn_repository.tar.gz"
    execute_command "restore_run_files ${restoreLocalRepositoryCache}_mvn_repository.tar.gz $repo_cache_file"
    if [ -f "$repo_cache_file" ]; then
      execute_command "mkdir -p $HOME/.m2/repository/"
      execute_command "tar -xf $repo_cache_file -C $HOME/.m2/repository/"
    fi
  fi

  buildDir=$(find_resource_variable "$inputGitRepoResourceName" resourcePath)/$sourceLocation
  execute_command "add_run_variables ${step_name}_build_directory='${buildDir}'"

  if [ ! -z "$restoreTargetCache" ]; then
    local target_cache_file="$step_tmp_dir/${restoreTargetCache}_target.tar.gz"
    execute_command "restore_run_files ${restoreTargetCache}_target.tar.gz $target_cache_file"
    if [ -f "$target_cache_file" ]; then
      execute_command "tar -xf $target_cache_file -C $buildDir"
    fi
  fi

  execute_command "pushd '$buildDir'"
    if [ ! -z "$configFileLocation" ] && [ ! -z "$configFileName" ]; then
      if [ ! -f "${configFileLocation}/${configFileName}" ]; then
        execute_command "echo 'Config file ${configFileLocation}/${configFileName} not found'"
        return 1
      fi
      execute_command "echo 'Moving config file from: ${configFileLocation}/${configFileName} to: .jfrog/projects/maven.yaml'"
      mkdir -p .jfrog/projects
      mv "${configFileLocation}/${configFileName}" $step_tmp_dir/maven.yaml
      mv $step_tmp_dir/maven.yaml .jfrog/projects/maven.yaml
    else
      configure_mvn "resolve" "deploy"
    fi

    local branchName=$(find_resource_variable "$inputGitRepoResourceName" branchName)
    local mvnConfig="${mavenConfig} -Dbuild.branch=\"$branchName\" -Ddeploy.build.branch=\"$branchName\" ${maven_config}"
    if [ ! -z "$mvnConfig" ]; then
      mkdir -p .mvn
      execute_command "echo \"$mvnConfig\" >> .mvn/maven.config"
    fi

    local generateBranchSpecificVersion=$(find_step_configuration_value "generateBranchSpecificVersion")
    if [ "$generateBranchSpecificVersion" == "true" ] && [[ "$branchName" != "master" ]]; then
      execute_command "echo 'Generating branch specific version for branch $branchName'"
      local version=$(get_maven_project_version)
      if [[ "$version" == *-SNAPSHOT ]]; then
        branchSpecificVersion="${version/-SNAPSHOT/-${branchName}-SNAPSHOT}"
        local branchSpecificVersionProperty=$(find_step_configuration_value "branchSpecificVersionProperty")
        set_maven_project_version "$branchSpecificVersion" "$branchSpecificVersionProperty"
      fi
    fi

    if [ -z "$mvnCommand" ]; then
      mvnCommand="clean install"
    fi
    if [ "$autoRetry" == "true" ]; then
      retry_mvn "$mvnCommand"
    else
      execute_mvn "$mvnCommand"
    fi

    execute_command "add_run_variables buildStepName='$step_name'"
    execute_command "add_run_variables ${step_name}_payloadType=mvn"
    execute_command "add_run_variables ${step_name}_buildNumber=$JFROG_CLI_BUILD_NUMBER"
    execute_command "add_run_variables ${step_name}_buildName='$JFROG_CLI_BUILD_NAME'"
    execute_command "add_run_variables ${step_name}_isPromoted=false"
  execute_command popd
  execute_command "jfrog rt build-collect-env  \"$JFROG_CLI_BUILD_NAME\" \"$JFROG_CLI_BUILD_NUMBER\""
  jiraIntegrationName=$(get_integration_name --type Jira)
  local tracker=""
  if [ -n "$jiraIntegrationName" ]; then
    tracker="--tracker=$jiraIntegrationName"
  fi
  execute_command "jfrog ext-build-info collect-issues $tracker \"$JFROG_CLI_BUILD_NAME\" \"$JFROG_CLI_BUILD_NUMBER\" $buildDir"
  if [ "$publish" == "true" ]; then
    if [ -z "$JFROG_CLI_ENV_EXCLUDE" ]; then
      execute_command 'export JFROG_CLI_ENV_EXCLUDE="res_*;int_*;current_*;*_dir;*password*;*secret*;*key*;*token*;BASH_FUNC_*"'
    fi
    execute_command "retry_command jfrog rt build-publish --detailed-summary --insecure-tls=$no_verify_ssl $JFROG_CLI_BUILD_NAME $JFROG_CLI_BUILD_NUMBER > $buildPublishOutputFile"
    execute_command "save_artifact_info buildInfo $buildPublishOutputFile --build-name $JFROG_CLI_BUILD_NAME --build-number $JFROG_CLI_BUILD_NUMBER"
    execute_command "cat $buildPublishOutputFile"
    if [ ! -z "$outputBuildInfoResourceName" ]; then
      execute_command "write_output $outputBuildInfoResourceName buildName=$JFROG_CLI_BUILD_NAME buildNumber=$JFROG_CLI_BUILD_NUMBER"
    fi
  fi
  if [ "$scan" == "true" ]; then
    if [ -z "$failOnScan" ]; then
      failOnScan="true"
    fi
    if [ $cli_major_version -gt 1 ]; then
      execute_command "check_xray_available"
    fi
    local xrayScanResultsOutputFile="$step_tmp_dir/xrayScanResultsOutput.json"
    onScanComplete() {
      execute_command "cat $xrayScanResultsOutputFile"
      if [ $cli_major_version -lt 2 ]; then
        xrayUrl=$(jq -c '.summary.more_details_url' "$xrayScanResultsOutputFile" --raw-output 2> /dev/null)
      else
        xrayUrl=$(jq -c '.[0].xray_data_url' "$xrayScanResultsOutputFile" --raw-output 2> /dev/null)
      fi
      if [ -n "$xrayUrl" ]; then
        execute_command "save_xray_results_url '$xrayUrl'"
      fi
    }
    if [ $cli_major_version -lt 2 ]; then
      execute_command "jfrog rt build-scan --insecure-tls=$no_verify_ssl --fail=$failOnScan $JFROG_CLI_BUILD_NAME $JFROG_CLI_BUILD_NUMBER > $xrayScanResultsOutputFile" || (onScanComplete; exit 99)
    else
      execute_command "jfrog build-scan --fail=${failOnScan} --format=json $JFROG_CLI_BUILD_NAME $JFROG_CLI_BUILD_NUMBER > $xrayScanResultsOutputFile" || (onScanComplete; exit 99)
    fi
    onScanComplete
  fi
  execute_command "add_run_files /tmp/jfrog/. jfrog"
}
MvnBuild
