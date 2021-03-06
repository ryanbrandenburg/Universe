#!/usr/bin/env bash

set -euo pipefail

#
# variables
#

RESET="\033[0m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
MAGENTA="\033[0;95m"
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
[ -z "${DOTNET_HOME:-}" ] && DOTNET_HOME="$HOME/.dotnet"
verbose=false
update=false
reinstall=false
repo_path="$DIR"
channel=''
tools_source=''
package_version_props_url=''
asset_root_url=''
access_token_suffix=''
restore_sources=''
product_build_id=''
msbuild_args=()

#
# Functions
#
__usage() {
    echo "Usage: $(basename "${BASH_SOURCE[0]}") command [options] [[--] <Arguments>...]"
    echo ""
    echo "Arguments:"
    echo "    command                The command to be run."
    echo "    <Arguments>...         Arguments passed to the command. Variable number of arguments allowed."
    echo ""
    echo "Options:"
    echo "    --verbose                                 Show verbose output."
    echo "    -c|--channel <CHANNEL>                    The channel of KoreBuild to download. Overrides the value from the config file.."
    echo "    --config-file <FILE>                      The path to the configuration file that stores values. Defaults to korebuild.json."
    echo "    -d|--dotnet-home <DIR>                    The directory where .NET Core tools will be stored. Defaults to '\$DOTNET_HOME' or '\$HOME/.dotnet."
    echo "    --path <PATH>                             The directory to build. Defaults to the directory containing the script."
    echo "    -s|--tools-source|-ToolsSource <URL>      The base url where build tools can be downloaded. Overrides the value from the config file."
    echo "    --package-version-props-url <URL>         The url of the package versions props path containing dependency versions."
    echo "    --access-token <Token>                    The query string to append to any blob store access for PackageVersionPropsUrl, if any."
    echo "    --restore-sources <Sources>               Semi-colon delimited list of additional NuGet feeds to use as part of restore."
    echo "    --product-build-id <ID>                   The product build ID for correlation with orchestrated builds."
    echo "    -u|--update                               Update to the latest KoreBuild even if the lock file is present."
    echo "    --reinstall                               Reinstall KoreBuild."
    echo ""
    echo "Description:"
    echo "    This function will create a file \$DIR/korebuild-lock.txt. This lock file can be committed to source, but does not have to be."
    echo "    When the lockfile is not present, KoreBuild will create one using latest available version from \$channel."

    if [[ "${1:-}" != '--no-exit' ]]; then
        exit 2
    fi
}

get_korebuild() {
    local version
    local lock_file="$repo_path/korebuild-lock.txt"
    if [ ! -f "$lock_file" ] || [ "$update" = true ]; then
        __get_remote_file "$tools_source/korebuild/channels/$channel/latest.txt" "$lock_file"
    fi
    version="$(grep 'version:*' -m 1 "$lock_file")"
    if [[ "$version" == '' ]]; then
        __error "Failed to parse version from $lock_file. Expected a line that begins with 'version:'"
        return 1
    fi
    version="$(echo "${version#version:}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    local korebuild_path="$DOTNET_HOME/buildtools/korebuild/$version"

    if [ "$reinstall" = true ] && [ -d "$korebuild_path" ]; then
        rm -rf "$korebuild_path"
    fi

    {
        if [ ! -d "$korebuild_path" ]; then
            mkdir -p "$korebuild_path"
            local remote_path="$tools_source/korebuild/artifacts/$version/korebuild.$version.zip"
            tmpfile="$(mktemp)"
            echo -e "${MAGENTA}Downloading KoreBuild ${version}${RESET}"
            if __get_remote_file "$remote_path" "$tmpfile"; then
                unzip -q -d "$korebuild_path" "$tmpfile"
            fi
            rm "$tmpfile" || true
        fi

        source "$korebuild_path/KoreBuild.sh"
    } || {
        if [ -d "$korebuild_path" ]; then
            echo "Cleaning up after failed installation"
            rm -rf "$korebuild_path" || true
        fi
        return 1
    }
}

__error() {
    echo -e "${RED}error: $*${RESET}" 1>&2
}

__warn() {
    echo -e "${YELLOW}warning: $*${RESET}"
}

__machine_has() {
    hash "$1" > /dev/null 2>&1
    return $?
}

__get_remote_file() {
    local remote_path=$1
    local local_path=$2

    if [[ "$remote_path" != 'http'* ]]; then
        cp "$remote_path" "$local_path"
        return 0
    fi

    local failed=false
    if __machine_has wget; then
        wget --tries 10 --quiet -O "$local_path" "$remote_path" || failed=true
    else
        failed=true
    fi

    if [ "$failed" = true ] && __machine_has curl; then
        failed=false
        curl --retry 10 -sSL -f --create-dirs -o "$local_path" "$remote_path" || failed=true
    fi

    if [ "$failed" = true ]; then
        __error "Download failed: $remote_path" 1>&2
        return 1
    fi
}

#
# main
#

command="${1:-}"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        -\?|-h|--help)
            __usage --no-exit
            exit 0
            ;;
        -c|--channel|-Channel)
            shift
            channel="${1:-}"
            [ -z "$channel" ] && __error "Missing value for parameter --channel" && __usage
            ;;
        --config-file|-ConfigFile)
            shift
            config_file="${1:-}"
            [ -z "$config_file" ] && __error "Missing value for parameter --config-file" && __usage
            if [ ! -f "$config_file" ]; then
                __error "Invalid value for --config-file. $config_file does not exist."
                exit 1
            fi
            ;;
        -d|--dotnet-home|-DotNetHome)
            shift
            DOTNET_HOME="${1:-}"
            [ -z "$DOTNET_HOME" ] && __error "Missing value for parameter --dotnet-home" && __usage
            ;;
        --path|-Path)
            shift
            repo_path="${1:-}"
            [ -z "$repo_path" ] && __error "Missing value for parameter --path" && __usage
            ;;
        -s|--tools-source|-ToolsSource)
            shift
            tools_source="${1:-}"
            [ -z "$tools_source" ] && __error "Missing value for parameter --tools-source" && __usage
            ;;
        --package-version-props-url|-PackageVersionPropsUrl)
            shift
            # This parameter can be an empty string, but it should be set
            [ -z "${1+x}" ] && __error "Missing value for parameter --package-version-props-url" && __usage
            package_version_props_url="$1"
            ;;
        --access-token-suffix|-AccessTokenSuffix)
            shift
            # This parameter can be an empty string, but it should be set
            [ -z "${1+x}" ] && __error "Missing value for parameter --access-token-suffix" && __usage
            access_token_suffix="$1"
            ;;
        --restore-sources|-RestoreSources)
            shift
            # This parameter can be an empty string, but it should be set
            [ -z "${1+x}" ] && __error "Missing value for parameter --restore-sources" && __usage
            restore_sources="$1"
            ;;
        --asset-root-url|-AssetRootUrl)
            shift
            # This parameter can be an empty string, but it should be set
            [ -z "${1+x}" ] && __error "Missing value for parameter --asset-root-url" && __usage
            asset_root_url="$1"
            ;;
        --product-build-id|-ProductBuildId)
            shift
            # This parameter can be an empty string, but it should be set
            [ -z "${1+x}" ] && __error "Missing value for parameter --product-build-id" && __usage
            product_build_id="$1"
            ;;
        -u|--update|-Update)
            update=true
            ;;
        --reinstall|-Reinstall)
            reinstall=true
            ;;
        --verbose|-Verbose)
            verbose=true
            ;;
        *)
            msbuild_args[${#msbuild_args[*]}]="$1"
            ;;
    esac
    shift
done

if ! __machine_has unzip; then
    __error 'Missing required command: unzip'
    exit 1
fi

if ! __machine_has curl && ! __machine_has wget; then
    __error 'Missing required command. Either wget or curl is required.'
    exit 1
fi

[ -z "${config_file:-}" ] && config_file="$repo_path/korebuild.json"
if [ -f "$config_file" ]; then
    if __machine_has jq ; then
        if jq '.' "$config_file" >/dev/null ; then
            config_channel="$(jq -r 'select(.channel!=null) | .channel' "$config_file")"
            config_tools_source="$(jq -r 'select(.toolsSource!=null) | .toolsSource' "$config_file")"
        else
            __warn "$config_file is invalid JSON. Its settings will be ignored."
        fi
    elif __machine_has python ; then
        if python -c "import json,codecs;obj=json.load(codecs.open('$config_file', 'r', 'utf-8-sig'))" >/dev/null ; then
            config_channel="$(python -c "import json,codecs;obj=json.load(codecs.open('$config_file', 'r', 'utf-8-sig'));print(obj['channel'] if 'channel' in obj else '')")"
            config_tools_source="$(python -c "import json,codecs;obj=json.load(codecs.open('$config_file', 'r', 'utf-8-sig'));print(obj['toolsSource'] if 'toolsSource' in obj else '')")"
        else
            __warn "$config_file is invalid JSON. Its settings will be ignored."
        fi
    else
        __warn 'Missing required command: jq or pyton. Could not parse the JSON file. Its settings will be ignored.'
    fi

    [ ! -z "${config_channel:-}" ] && channel="$config_channel"
    [ ! -z "${config_tools_source:-}" ] && tools_source="$config_tools_source"
fi

if [ ! -z "$package_version_props_url" ]; then
    intermediate_dir="$repo_path/obj"
    props_file_path="$intermediate_dir/external-dependencies.props"
    mkdir -p "$intermediate_dir"
    __get_remote_file "$package_version_props_url" "$props_file_path"
    msbuild_args[${#msbuild_args[*]}]="-p:DotNetPackageVersionPropsPath=$props_file_path"
fi

if [ ! -z "$restore_sources" ]; then
    msbuild_args[${#msbuild_args[*]}]="-p:DotNetAdditionalRestoreSources=$restore_sources"
fi

if [ ! -z "$asset_root_url" ]; then
    msbuild_args[${#msbuild_args[*]}]="-p:DotNetAssetRootUrl=$asset_root_url"
fi

if [ ! -z "$access_token_suffix" ]; then
    msbuild_args[${#msbuild_args[*]}]="-p:DotNetAssetRootAccessTokenSuffix=$access_token_suffix"
fi

if [ ! -z "$product_build_id" ]; then
    msbuild_args[${#msbuild_args[*]}]="-p:DotNetProductBuildId=$product_build_id"
fi

[ -z "$channel" ] && channel='dev'
[ -z "$tools_source" ] && tools_source='https://aspnetcore.blob.core.windows.net/buildtools'

get_korebuild
set_korebuildsettings "$tools_source" "$DOTNET_HOME" "$repo_path" "$config_file"

# This incantation avoids unbound variable issues if msbuild_args is empty
# https://stackoverflow.com/questions/7577052/bash-empty-array-expansion-with-set-u
invoke_korebuild_command "$command" ${msbuild_args[@]+"${msbuild_args[@]}"}
