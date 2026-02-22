_ev() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="scan clean purge analyze status config help"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands} --help --version" -- "${cur}") )
        return 0
    fi

    local subcmd="${COMP_WORDS[1]}"

    if [[ "${prev}" == "--category" || "${prev}" == "-c" ]]; then
        COMPREPLY=( $(compgen -W "dev system package ai browser" -- "${cur}") )
        return 0
    fi

    case "${subcmd}" in
        scan)
            COMPREPLY=( $(compgen -W "-c --category -h --help" -- "${cur}") )
            ;;
        clean)
            COMPREPLY=( $(compgen -W "--dry-run --force --dev --system --package --ai --browser -c --category -h --help" -- "${cur}") )
            ;;
        purge)
            COMPREPLY=( $(compgen -W "--depth --dry-run --force -h --help" -- "${cur}") )
            ;;
        analyze)
            COMPREPLY=( $(compgen -W "--depth --top -h --help" -- "${cur}") )
            ;;
        status)
            COMPREPLY=( $(compgen -W "-h --help" -- "${cur}") )
            ;;
        config)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                COMPREPLY=( $(compgen -W "show whitelist -h --help" -- "${cur}") )
            fi
            ;;
    esac

    return 0
}

complete -F _ev ev
