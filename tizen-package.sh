#!/usr/bin/env bash

script="${BASH_SOURCE[0]}"
script_name=${script##*/}
script_dir=$(readlink -f $(dirname $script))

RXP_PACKAGE_NAME="[a-zA-Z0-9_]"

usage() {
  echo "${script_name} ACTION [[OPTIONS...]]"
  echo -e "\tACTION"
  for action in build install uninstall deploy run inspect; do
    echo -e "\t\t${action}"
  done
}

# Process command line parameters
declare -A options
action=$1
shift
while [[ "${1:0:2}" == "--" ]]; do
    option=${1:2}
    value=""
    shift
    if [[ "${1:0:2}" != '--' ]]; then
        value="$1"
        shift
    fi
    options[$option]=${value:-true}
done


share_dir="${HOME}/.local/share/tizen-packager"
working_dir=$PWD
tizen_dir="${working_dir}/tizen"
build_dir="${tizen_dir}/build"
dist="${options[dist]:-${working_dir}/dist}"

chrome=${options[chrome]:-google-chrome}
host="${options[host]}"
port="${options[port]:-26101}"
sign="${options[sign]:-dev}"

device_ip=$host
device_port=$port

COLOR_BRIGHT='\033[1m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m' # No Color

error_message() {
  echo -e "\n${COLOR_RED}${1}${COLOR_RESET}"
}

quit_on_error() {
  if [[ $2 -gt 0 ]]; then
    error_message "Failed ${1}: ${2}"
    notify-send --app-name="$script_name" --urgency="critical" "${script_name} failed to ${1}"
    exit $2
  fi
}

cmd() {
  echo -e "\n${COLOR_BRIGHT}command: ${COLOR_YELLOW}${*}${COLOR_RESET}"
  $*
}

require_parameter() {
  parameter_name=$1
  [[ -z "${options[${parameter_name}]}" ]] && {
    error_message "Missing --${parameter_name} parameter"
    exit 1
  }
}

create_config() {
  default_pkg_name="$(echo ${PWD##*/} | tr -cd $RXP_PACKAGE_NAME)"
  read -p "Package name (no space) [default ${default_pkg_name}]: " answer
  pkg_name="${answer:-$default_pkg_name}"
  echo "${pkg_name}" | grep -v  $RXP_PACKAGE_NAME
  if [[ $? -eq 0 ]]; then
    echo "Invalid package name, only alphanumeric and underscore accepted"
    exit 1
  fi

  echo "pkg_name: $pkg_name"
  mkdir "$tizen_dir"
  cp -v "${share_dir}/config.xml" "$tizen_dir"
  pkg_id="$(tr -cd "a-zA-Z0-9" < /dev/random | head -c 1024 | grep -Eo "[^0-9][a-zA-Z0-9]{9}" | head -n 1)"
  pkg_version="0.0.1"
  sed "s/%PKG_ID%/${pkg_id}/g" -i "${tizen_dir}/config.xml"
  sed "s/%PKG_NAME%/${pkg_name}/g" -i "${tizen_dir}/config.xml"
  sed "s/%PKG_VERSION%/${pkg_version}/g" -i "${tizen_dir}/config.xml"
  if [[ -z "$(which convert)" ]]; then 
    echo "Needs ImageMagick to generate icon, copying the default icon..."
    cp -v "${share_dir}/icon.png" "${tizen_dir}/icon.png"
    exit 1
  fi
  convert "${share_dir}/icon.png" -fill white -gravity South -pointsize 90 -annotate +0+100 "$pkg_name" "${tizen_dir}/icon.png"
}

connect() {
  cmd sdb connect "${device_ip}:${device_port}" | grep failed && exit 1
}

send_device() {
  echo "$1" | xxd -r -p | nc -w 1 "${device_ip}" "${device_port}"
}

build() {
  # clean build dir
  rm -r "${build_dir}"
  mkdir -v "${build_dir}"

  if [[ -d $dist ]]; then
    cp -rv "${dist}"/* "${build_dir}"
  elif [[ -e $dist ]]; then
    cp -v "${dist}" "${build_dir}/index.html"
  else
    error_message "No di files found: ${dist}"
    exit 1
  fi

  # Copy web files files
  if [[ "${options[target-url]}" ]]; then
    entry=${options[entry]:-index}
    base_href=$(echo "${options[target-url]}" | sed 's/\//\\\//g')
    sed "/<head>/a\ \ \ \ <base href=\"${base_href}\">" -i "${build_dir}/index.html"
  fi

  # Copy tizen files
  cp -vr "${tizen_dir}"/{config.xml,icon.png} "${build_dir}"
  sed "s/%PKG_VERSION%/${pkg_version}/g" -i "${build_dir}/config.xml"
  cmd tizen package --type wgt --sign ${sign} --output "${working_dir}" -- "${build_dir}"
  mv -v "${working_dir}/${pkg_name}.wgt" "${working_dir}/${pkg_name}-${pkg_version}.wgt"
}


install() {
  cmd tizen install -n "${working_dir}/${pkg_name}-${pkg_version}.wgt" -s "${device_ip}:${device_port}"
  quit_on_error 'install' $?
}

uninstall() {
  cmd tizen uninstall -p "${pkg_full_id}" -s "${device_ip}:${device_port}"
  quit_on_error 'uninstall' $?
}

run() {
  cmd tizen run -p "${pkg_full_id}" -s "${device_ip}:${device_port}"
  quit_on_error 'run' $?
}


action_create() {
  echo "Tizen config folder already exists"
  exit 1
}

action_build() {
  build
}

action_uninstall() {
  require_parameter "host"

  uninstall
}

action_install() {
  require_parameter "host"

  build
  connect
  install
}

action_inspect() {
  require_parameter "host"

  # CNXN command payload
  payload_connect="434e584e00001000000004000700000032020000bcb1a7b1686f73743a3a00"
  
  # Generate the open debug command
  payload_length=$(( ${#pkg_full_id} + 17 ))
  hex_payload_length=$(printf "%02x" "${payload_length}")
  hex_pkg_id="$(echo -n ${pkg_full_id} | hexdump -v -e '/1 "%02X"')"
  # OPEN command payload like 'OPEN ... shell: debug "${pkg_id}.${pkg_name}"'
  payload_open_command="7368656c6c3a302064656275672022${hex_pkg_id}2200"
  crc=$(echo "${payload_open_command}" | xxd -r -p | python -c "import sys; print(sum([ ord(x) for x in sys.stdin.read() ]).to_bytes(2, byteorder='little').hex())")
  payload_open=$(echo -n "4f50454e0200000000000000${hex_payload_length}000000${crc}0000b0afbab1${payload_open_command}")
  
  #send_device "$payload_connect"
  #output=$(send_device "$payload_open")

  output=$({
    echo -n "$payload_connect"
    echo -n "$payload_open"
  } | xxd -r -p | nc -w 2 "${device_ip}" "${device_port}")

  debug_port=$(echo "$output" | strings | grep -Eo "port: [0-9]+" | sed 's/^port: //')

  if [[ "$debug_port" ]]; then
    echo "debug_port: $debug_port"
    debug_url="http://${device_ip}:${debug_port}"
    inspector_pathname=$(curl -s "$debug_url/json" | grep -o '/devtools/inspector[^"]*')
    inspector_url="${debug_url}${inspector_pathname}"
    $chrome --enable-blink-features=ShadowDOMV0,CustomElementsV0,HTMLImports "$inspector_url"
  else
    echo "Unable to open debug session. Make sure the application is closed before inspect"
  fi
}

action_deploy() {
  require_parameter "host"

  build
  connect
  [[ "${options[uninstall]}" ]] && uninstall
  install
  run
}

action_run() {
  require_parameter "host"

  run
}

if [[ ! -e "$working_dir/tizen" ]]; then
  echo "No tizen config folder found"
  create_config
fi

if [[ -e "$working_dir/tizen" ]]; then
  pkg_name_id=$(cat "${tizen_dir}/config.xml" | grep "<tizen:application" | grep -o 'id="[^"]*"' | cut -d '"' -f2)
  IFS=. read pkg_id pkg_name <<< "$pkg_name_id"  
  pkg_version="${options[version]:-0.0.1}"
  pkg_full_id="${pkg_id}.${pkg_name}"  
  echo -e "${COLOR_BRIGHT}${action} ${pkg_name_id} ${pkg_version}${COLOR_RESET}\n"
  #pkg_version=$(cat "${tizen_dir}/config.xml" | grep "<widget" | grep -o 'version="[^"]*"' | cut -d '"' -f2)
  case "$action" in
    "create")
      action_create;;
    "build")
      action_build;;
    "uninstall")
      uninstall;;
    "install")
      action_install;;
    "deploy")
      action_deploy;;
    "run")
      action_run;;
    "inspect")
      action_inspect;;
    *)
      usage;;
  esac
  notify-send "${script_name} $action successful"
fi
