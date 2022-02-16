_os4instancectl()
{
  local cur prev opts diropts
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  opts="ls add rm start stop update erase autoscale"
  opts+=" --help --long --metadata --online --offline --error --no-pid-file"
  opts+=" --clone-from --force --color --project-dir --fast --patient"
  opts+=" --local-only"
  opts+=" --version --tag --management-tool"
  opts+=" --compose-template --config-template"
  opts+=" --reset --allow-downscale --accounts --dry-run"
  diropts="ls|rm|start|stop|update|erase|autoscale|--clone-from"

  if [[ ${prev} =~ ${diropts} ]]; then
    COMPREPLY=( $(cd /srv/openslides/os4-instances && compgen -d -- ${cur}) )
    return 0
  fi

  if [[ ${prev} == --*template ]]; then
    _filedir
    return 0
  fi

  if [[ ${prev} =~ --management-tool|-O ]]; then
    _filedir
    return 0
  fi

  if [[ ${cur} == * ]] ; then
    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    return 0
  fi
}

complete -F _os4instancectl os4instancectl
