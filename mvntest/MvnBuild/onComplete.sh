add_artifact()
{
  local name=$1
  local pattern=$2
  local path=$3
  if [ -z "$path" ]; then
    path="."
  fi

  execute_command "echo 'Packaging artifact $name'"

  pushd $path
    IFS=$'\n' files=( $(eval "find . -type f -path '${pattern}' -exec echo '{}'  \;") )

    if [ "$DEBUG" == "true" ]; then
      execute_command "echo 'Found the following files using $pattern in $path':"
      for file in ${files[@]}; do
        echo "$file"
      done
    fi

    if (( ! ${#files[@]} )); then
      execute_command "echo 'No files to found using pattern ${pattern} in ${path}'"
    elif [ ${#files[@]} -gt 1 ]; then
      execute_command "echo 'Packaged a tarball ${name}.tar.gz with ${#files[@]} files'"
      tar cf "$step_tmp_dir/${name}.tar.gz" "${files[@]}"
      add_run_files "$step_tmp_dir/${name}.tar.gz" "${name}.tar.gz"
    else
      execute_command "echo 'Found ${files[0]}'"
      add_run_files "${files[0]}" "${name}"
    fi
  popd
}
export -f add_artifact

MvnBuildCompleted()
{
  testLocation=$(find_step_configuration_value "testLocation")
  addLocalRepositoryCache=$(find_step_configuration_value "addLocalRepositoryCache")
  addTargetCache=$(find_step_configuration_value "addTargetCache")
  artifacts=$(find_step_configuration_value "artifacts")
  buildDir=$(eval echo "$""$step_name"_build_directory)

  execute_command "pushd '$buildDir'"
    if [ ! -z "$testLocation" ]; then
      execute_command "echo 'Saving tests from $testLocation'"
      local testsDir="${step_tmp_dir}/tests"
      mkdir -p $testsDir
      find . -path "${testLocation}" -exec cp '{}' $testsDir  \;
      save_tests $testsDir
      if [ "$DEBUG" == "true" ]; then
        execute_command 'echo "Found the following tests"'
        ls -la $testsDir
      fi
    fi

    if [ "$addTargetCache" == "true" ]; then
      execute_command 'echo "Caching build output"'
      add_artifact "${step_name}_target" '*/target/*'
    fi

    if [ "$addLocalRepositoryCache" == "true" ]; then
      execute_command 'echo "Caching Maven local repository"'
      tar -czf "$step_tmp_dir/${step_name}_mvn_repository.tar.gz" -C "$HOME/.m2/repository" .
      add_run_files "$step_tmp_dir/${step_name}_mvn_repository.tar.gz" "${step_name}_mvn_repository.tar.gz"
      if [ "$DEBUG" == "true" ]; then
        execute_command "echo 'Packaged the following in ${step_name}_mvn_repository.tar.gz'"
        tar -tvf "$step_tmp_dir/${step_name}_mvn_repository.tar.gz"
      fi
    fi

    if [ ! -z "$step_configuration_artifacts_len" ] && [ $step_configuration_artifacts_len -gt 0 ]; then
      for (( c=0; c<$step_configuration_artifacts_len; c++ )); do
        local name=$(find_step_configuration_value "artifacts_${c}_name")
        local pattern=$(find_step_configuration_value "artifacts_${c}_pattern")
        local path=$(find_step_configuration_value "artifacts_${c}_path")

        add_artifact $name $pattern $path
      done
    fi
  execute_command popd
}
MvnBuildCompleted
