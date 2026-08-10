_database() {
    local current="${COMP_WORDS[COMP_CWORD]}"
    local prefix="${COMP_WORDS[*]:1:COMP_CWORD-1}"
    local commands="auth login auth logout base activate base create base delete base describe base legacy-migration apply base legacy-migration plan base list base placement apply base placement plan base placements base retire capabilities command run completion bash completion fish completion zsh composition create composition delete composition describe composition list composition replace doctor entity apply entity delete entity insert entity update entity upsert fdb grant add grant direct grant effective grant revoke graph community graph cycles graph page-rank graph shortest-path graph strongly-connected-components graph topological-sort graph weighted-shortest-path index rebuild index status inspect entities inspect graph inspect indexes inspect jobs inspect ontology inspect overview inspect shapes job cancel job result job status job wait maintenance compact migration run migration status mutate sparql mutate sql ontology delete ontology describe ontology hierarchy ontology reason ontology upsert ontology validate-schema open profile create profile list profile remove profile show profile use query sparql query sql schema apply schema list schema plan schema show serve shacl delete shacl describe shacl upsert shacl validate shell version"
    if [[ -z "$prefix" ]]; then
        COMPREPLY=( $(compgen -W "auth base capabilities command completion composition doctor entity fdb grant graph help index inspect job maintenance migration mutate ontology open profile query schema serve shacl shell version" -- "$current") )
    else
        COMPREPLY=( $(compgen -W "$commands" -- "$prefix $current") )
        COMPREPLY=( "${COMPREPLY[@]#"$prefix "}" )
    fi
}
complete -F _database database
