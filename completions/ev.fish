complete -c ev -f
complete -c ev -n '__fish_use_subcommand' -a scan -d 'Scan for reclaimable space'
complete -c ev -n '__fish_use_subcommand' -a clean -d 'Clean selected items'
complete -c ev -n '__fish_use_subcommand' -a purge -d 'Find projects and clean build artifacts'
complete -c ev -n '__fish_use_subcommand' -a analyze -d 'Disk usage analysis'
complete -c ev -n '__fish_use_subcommand' -a status -d 'System dashboard'
complete -c ev -n '__fish_use_subcommand' -a config -d 'Configuration management'
complete -c ev -n '__fish_use_subcommand' -a help -d 'Show help'
complete -c ev -n '__fish_use_subcommand' -s h -l help -d 'Show help'
complete -c ev -n '__fish_use_subcommand' -s v -l version -d 'Show version'

# scan
complete -c ev -n '__fish_seen_subcommand_from scan' -s c -l category -xa 'dev system package ai browser' -d 'Filter by category'
complete -c ev -n '__fish_seen_subcommand_from scan' -s h -l help -d 'Show help'
complete -c ev -n '__fish_seen_subcommand_from scan' -F -d 'Path to scan'

# clean
complete -c ev -n '__fish_seen_subcommand_from clean' -l dry-run -d 'Show what would be deleted'
complete -c ev -n '__fish_seen_subcommand_from clean' -l force -d 'Delete without confirmation'
complete -c ev -n '__fish_seen_subcommand_from clean' -l dev -d 'Only dev artifacts'
complete -c ev -n '__fish_seen_subcommand_from clean' -l system -d 'Only system caches'
complete -c ev -n '__fish_seen_subcommand_from clean' -l package -d 'Only package manager caches'
complete -c ev -n '__fish_seen_subcommand_from clean' -l ai -d 'Only AI/ML model caches'
complete -c ev -n '__fish_seen_subcommand_from clean' -l browser -d 'Only browser caches'
complete -c ev -n '__fish_seen_subcommand_from clean' -s c -l category -xa 'dev system package ai browser' -d 'Filter by category'
complete -c ev -n '__fish_seen_subcommand_from clean' -s h -l help -d 'Show help'

# purge
complete -c ev -n '__fish_seen_subcommand_from purge' -l depth -x -d 'Maximum scan depth'
complete -c ev -n '__fish_seen_subcommand_from purge' -l dry-run -d 'Show what would be deleted'
complete -c ev -n '__fish_seen_subcommand_from purge' -l force -d 'Delete without confirmation'
complete -c ev -n '__fish_seen_subcommand_from purge' -s h -l help -d 'Show help'
complete -c ev -n '__fish_seen_subcommand_from purge' -F -d 'Path to purge'

# analyze
complete -c ev -n '__fish_seen_subcommand_from analyze' -l depth -x -d 'Scan depth'
complete -c ev -n '__fish_seen_subcommand_from analyze' -l top -x -d 'Number of top directories'
complete -c ev -n '__fish_seen_subcommand_from analyze' -s h -l help -d 'Show help'
complete -c ev -n '__fish_seen_subcommand_from analyze' -F -d 'Path to analyze'

# status
complete -c ev -n '__fish_seen_subcommand_from status' -s h -l help -d 'Show help'

# config
complete -c ev -n '__fish_seen_subcommand_from config' -a 'show' -d 'Show current configuration'
complete -c ev -n '__fish_seen_subcommand_from config' -a 'whitelist' -d 'Add a path to the whitelist'
complete -c ev -n '__fish_seen_subcommand_from config' -s h -l help -d 'Show help'
