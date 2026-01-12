#!/usr/bin/env bash
# Bash completion for cac (Coding Agent Config)
# Install: source /path/to/cac.bash
# Or copy to /etc/bash_completion.d/cac or ~/.local/share/bash-completion/completions/cac

# shellcheck disable=SC2207  # COMPREPLY=($(compgen ...)) is standard completion idiom

_cac_completions() {
    local cur prev words cword
    _init_completion -n = || return

    local commands="push pull get list test"
    local global_opts="--help -h --version -v --verbose"
    local push_opts="--user --dry-run"
    local pull_opts="--user --dry-run"
    local list_opts="--host --user"
    local get_opts="--user"
    local test_opts="--user"

    # Find the command (first non-option argument after 'cac')
    local cmd=""
    local i
    for ((i = 1; i < cword; i++)); do
        case "${words[i]}" in
            -*) ;;  # Skip options
            *)
                cmd="${words[i]}"
                break
                ;;
        esac
    done

    # Complete command-specific options
    case "$cmd" in
        push)
            case "$prev" in
                --user)
                    # Complete with usernames from /etc/passwd
                    COMPREPLY=($(compgen -u -- "$cur"))
                    return
                    ;;
            esac
            COMPREPLY=($(compgen -W "$push_opts" -- "$cur"))
            return
            ;;
        pull)
            case "$prev" in
                --user)
                    COMPREPLY=($(compgen -u -- "$cur"))
                    return
                    ;;
            esac
            COMPREPLY=($(compgen -W "$pull_opts" -- "$cur"))
            return
            ;;
        list)
            case "$prev" in
                --host)
                    # Could complete with known hosts, but that's not practical
                    # User will type their own hostname
                    return
                    ;;
                --user)
                    COMPREPLY=($(compgen -u -- "$cur"))
                    return
                    ;;
            esac
            COMPREPLY=($(compgen -W "$list_opts" -- "$cur"))
            return
            ;;
        get)
            case "$prev" in
                --user)
                    COMPREPLY=($(compgen -u -- "$cur"))
                    return
                    ;;
            esac
            # For 'get', we could complete bundle names but that requires API call
            # Just offer options
            COMPREPLY=($(compgen -W "$get_opts" -- "$cur"))
            return
            ;;
        test)
            case "$prev" in
                --user)
                    COMPREPLY=($(compgen -u -- "$cur"))
                    return
                    ;;
            esac
            COMPREPLY=($(compgen -W "$test_opts" -- "$cur"))
            return
            ;;
    esac

    # No command yet - complete with commands and global options
    case "$cur" in
        -*)
            COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            ;;
        *)
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            ;;
    esac
}

# Register the completion function
complete -F _cac_completions cac
