_database_completion() {
  local current previous top
  COMPREPLY=()
  current="${COMP_WORDS[COMP_CWORD]}"
  previous="${COMP_WORDS[COMP_CWORD-1]}"
  top="${COMP_WORDS[1]}"

  if [[ "$current" == --* ]]; then
    COMPREPLY=( $(compgen -W '--profile --endpoint --database --tenant --workspace --trace-id --idempotency-key --maximum-rows --maximum-work-units --maximum-intermediate-rows --maximum-intermediate-bytes --timeout-milliseconds --page-size --continuation --output --as-job --all --max-total-rows --max-total-bytes --max-pages --help' -- "$current") )
    return
  fi
  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W 'profile auth capabilities schema query mutate entity graph ontology shacl command migration index maintenance job shell fdb' -- "$current") )
    return
  fi
  case "$top" in
    profile) COMPREPLY=( $(compgen -W 'create list show use remove' -- "$current") ) ;;
    auth) COMPREPLY=( $(compgen -W 'login logout' -- "$current") ) ;;
    schema) COMPREPLY=( $(compgen -W 'list show' -- "$current") ) ;;
    query|mutate) COMPREPLY=( $(compgen -W 'sql sparql' -- "$current") ) ;;
    entity) COMPREPLY=( $(compgen -W 'insert update upsert delete apply' -- "$current") ) ;;
    graph) COMPREPLY=( $(compgen -W 'shortest-path weighted-shortest-path page-rank community cycles strongly-connected-components topological-sort' -- "$current") ) ;;
    ontology) COMPREPLY=( $(compgen -W 'describe upsert delete reason hierarchy validate-schema' -- "$current") ) ;;
    shacl) COMPREPLY=( $(compgen -W 'describe upsert delete validate' -- "$current") ) ;;
    command) COMPREPLY=( $(compgen -W 'run' -- "$current") ) ;;
    migration) COMPREPLY=( $(compgen -W 'status run' -- "$current") ) ;;
    index) COMPREPLY=( $(compgen -W 'status rebuild' -- "$current") ) ;;
    maintenance) COMPREPLY=( $(compgen -W 'compact' -- "$current") ) ;;
    job) COMPREPLY=( $(compgen -W 'status wait result cancel' -- "$current") ) ;;
    fdb) COMPREPLY=( $(compgen -W 'cluster catalog raw' -- "$current") ) ;;
  esac
}
complete -F _database_completion database
