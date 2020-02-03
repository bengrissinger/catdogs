#!/bin/bash

# a script for consuming short & long arguments declares in file 'args_file'
main() {

    readonly CMD_HELP="##EXECUTE_HELP"
    readonly TEMPLATE_LINE_STRUCT="(.*)=(.*)(##(.*)?)" # \1: arg options \2: env_var name \3: comment to display in help
    readonly args_file="${1}"

    if [[ ! -f "${args_file}" ]]; then

        echo "ERROR: file not found '${args_file}'"
        echo "USAGE: ./args_to_vars.sh <args_file> <args to consume>..."
        exit 1
    fi

    env_vars="$(consumeArguments ${@:2})"
    local exit_code=$?

    if [[ "$exit_code" == 1 ]]; then
        printHelp
        exit 0
    else
        echo "$env_vars" > args_to_vars_env_list
        source args_to_vars_env_list
        rm args_to_vars_env_list
    fi
}

consumeArguments() {

    local args=(${@})
    local key=""
    local value=""
    local longArg=""

    if [[ $# = 0 ]]; then
        return 1
    fi

    while (( ${#args[@]} >= 1 )); do

        longArg=$(allowedArgumentsFromFile "${args[0]}")
        [[ $? == 0 && ! -z "$longArg" ]] && key="${longArg}" || value="${args[0]}"

        if [[ "$key" == "$CMD_HELP" ]]; then # show help if help argument found

            return 1
        fi

        if [[ ! -z "$key" && ! -z "$value" ]]; then

            echo "export set ${key}=${value}"
            key=""
            value=""
        fi

        args=(${args[@]:1})
    done

    return 0
}

allowedArgumentsFromFile() {

    if [[ -f "${args_file}" ]]; then

        local query="${1//-/\-}"
        local line=$(stripMetadata | grep -e "$query," -e "$query=")
        local env_var_name="${line#*=}"
        local allowed_command="${line/=*}"
        allowed_command=("${allowed_command//,/ }")

        for command in ${allowed_command[@]}; do
            if [[ "$command" == "$1" ]]; then

                echo "$env_var_name" | grep -v "^$"
                return 0
            fi
        done

        return 1
    else

        echo "ERROR: file not found '${args_file}'"
        return 1
    fi
}

printHelp() {

    if [[ -f "${args_file}" ]]; then

        local manual="$(cat ${args_file})"
        local manualArgs="$(echo "${manual}" | grep -v -e '^##' -e '^$' | sed -Ee "s/${TEMPLATE_LINE_STRUCT}/\1\:\4/g" -e 's/^/\\t/g' | column -s ':' -t)"
        local manualText="$(echo "${manual}" | grep '^##')"

        echo "${manualText//##/}"
        echo -e "${manualArgs}" | sort
    fi
}

stripMetadata() {

    cat "$args_file" | grep -v "^##" | sed -E "s/${TEMPLATE_LINE_STRUCT}/\1=\2/g"
}

main $@
