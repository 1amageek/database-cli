complete -c database -f
complete -c database -n '__fish_use_subcommand' -a 'profile auth capabilities schema query mutate entity graph ontology shacl command migration index maintenance job shell fdb'
complete -c database -l profile -r
complete -c database -l endpoint -r
complete -c database -l database -r
complete -c database -l tenant -r
complete -c database -l workspace -r
complete -c database -l trace-id -r
complete -c database -l idempotency-key -r
complete -c database -l page-size -r
complete -c database -l continuation -r
complete -c database -l output -r -a 'table jsonl json csv nquads'
complete -c database -l as-job -r
complete -c database -l all
complete -c database -l max-total-rows -r
complete -c database -l max-total-bytes -r
complete -c database -l max-pages -r

complete -c database -n '__fish_seen_subcommand_from profile' -a 'create list show use remove'
complete -c database -n '__fish_seen_subcommand_from auth' -a 'login logout'
complete -c database -n '__fish_seen_subcommand_from schema' -a 'list show'
complete -c database -n '__fish_seen_subcommand_from query mutate' -a 'sql sparql'
complete -c database -n '__fish_seen_subcommand_from entity' -a 'insert update upsert delete apply'
complete -c database -n '__fish_seen_subcommand_from graph' -a 'shortest-path weighted-shortest-path page-rank community cycles strongly-connected-components topological-sort'
complete -c database -n '__fish_seen_subcommand_from ontology' -a 'describe upsert delete reason hierarchy validate-schema'
complete -c database -n '__fish_seen_subcommand_from shacl' -a 'describe upsert delete validate'
complete -c database -n '__fish_seen_subcommand_from command' -a 'run'
complete -c database -n '__fish_seen_subcommand_from migration' -a 'status run'
complete -c database -n '__fish_seen_subcommand_from index' -a 'status rebuild'
complete -c database -n '__fish_seen_subcommand_from maintenance' -a 'compact'
complete -c database -n '__fish_seen_subcommand_from job' -a 'status wait result cancel'
complete -c database -n '__fish_seen_subcommand_from fdb' -a 'cluster catalog raw'
