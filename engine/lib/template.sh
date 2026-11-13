# engine/lib/template.sh - bash templates (engine/templates/*.tpl), the bash version of Ansible's Jinja2.
#
#   tpl_render NAME            prints templates/NAME with the current shell variables filled in
#
# Syntax (a template is the config file itself, plus these):
#   {{ var }}                  value of the bash variable "var" (an unset variable is an error, so a
#                              typo cannot silently write an empty value)
#   {% if BASH-CONDITION %}    lines kept only when the condition is true, e.g.
#   {% elif BASH-CONDITION %}      {% if [[ $setup_type == docker_stack ]] %}
#   {% else %}                     {% if [[ -n $traffic_idle_timeout ]] %}
#   {% endif %}
#   {% for x in ARRAY %}       the lines repeated for each element of the bash array ARRAY,
#   {% endfor %}               with {{ x }} set to the element
#   {% include NAME %}         another template, inserted here (e.g. a shared server block body)
#   {# comment #}              a template comment (one or more whole lines), never written to the output
#
# A line holding only a {% %} or {# #} tag is removed completely (like Ansible's trim_blocks).
# Everything else is copied as it is: nginx's $uri, $host, PHP-FPM's ";" comments and so on need no
# escaping. Conditions are bash, run with eval: templates are part of the deployer, never user input.

TPL_DIR=${TPL_DIR:-$ENGINE_DIR/templates}

tpl_render() {
  local _tpl_file=$TPL_DIR/$1
  [[ -f $_tpl_file ]] || { echo "template not found: $_tpl_file" >&2; return 1; }
  local -a _TPL_L
  mapfile -t _TPL_L < "$_tpl_file"
  _TPL_NAME=$1 _tpl_block 0 "${#_TPL_L[@]}"
}

# _tpl_tag LINE: when LINE is only a {% %} tag, sets _TPL_T to its inside and returns 0
# (no $(...) here or below: a subshell per line would make a long template slow)
_tpl_tag() {
  [[ $1 =~ ^[[:space:]]*\{%[[:space:]]*(.*[^[:space:]])[[:space:]]*%\}[[:space:]]*$ ]] || return 1
  _TPL_T=${BASH_REMATCH[1]}
}

# _tpl_end FROM TO: sets _TPL_J to the index of the {% endif %} / {% endfor %} that closes the block
# opened just before FROM, and _TPL_BR to the indexes of this block's own elif/else lines
_tpl_end() {
  local _t_i _t_depth=0 _t_t
  _TPL_BR=()
  for ((_t_i = $1; _t_i < $2; _t_i++)); do
    if [[ ${_TPL_L[_t_i]} =~ ^[[:space:]]*\{# ]]; then
      while ((_t_i < $2)) && [[ ${_TPL_L[_t_i]} != *'#}'* ]]; do _t_i=$((_t_i + 1)); done
      continue
    fi
    _tpl_tag "${_TPL_L[_t_i]}" || continue
    _t_t=$_TPL_T
    case $_t_t in
      'if '*|'for '*) _t_depth=$((_t_depth + 1)) ;;
      endif|endfor)
        if ((_t_depth == 0)); then _TPL_J=$_t_i; return 0; fi
        _t_depth=$((_t_depth - 1)) ;;
      'elif '*|else) ((_t_depth > 0)) || _TPL_BR+=("$_t_i") ;;
    esac
  done
  echo "$_TPL_NAME: line $1: {% if %} or {% for %} is never closed" >&2
  return 1
}

# _tpl_block FROM TO: renders lines FROM..TO-1. Its own variables all start with _t_, so a template
# variable (or a {% for %} variable) can never be mixed up with them.
_tpl_block() {
  local _t_i=$1 _t_end=$2 _t_t _t_line _t_out _t_name _t_rest _t_val _t_cond _t_j _t_k _t_stop
  local -a _t_br
  while ((_t_i < _t_end)); do
    _t_line=${_TPL_L[_t_i]}
    if [[ $_t_line =~ ^[[:space:]]*\{# ]]; then   # a comment, possibly over several lines
      while ((_t_i < _t_end)) && [[ ${_TPL_L[_t_i]} != *'#}'* ]]; do _t_i=$((_t_i + 1)); done
      _t_i=$((_t_i + 1)); continue
    fi
    if _tpl_tag "$_t_line"; then
      _t_t=$_TPL_T
      case $_t_t in
        'if '*)
          _tpl_end $((_t_i + 1)) "$_t_end" || return 1
          _t_j=$_TPL_J; _t_br=("${_TPL_BR[@]}" "$_t_j")
          _t_cond=${_t_t#if }; _t_k=$_t_i
          for _t_stop in "${_t_br[@]}"; do
            if [[ -n $_t_cond ]] && eval "$_t_cond"; then
              _tpl_block $((_t_k + 1)) "$_t_stop" || return 1
              break
            fi
            _tpl_tag "${_TPL_L[_t_stop]}"; _t_t=$_TPL_T
            case $_t_t in 'elif '*) _t_cond=${_t_t#elif } ;; else) _t_cond=true ;; *) _t_cond='' ;; esac
            _t_k=$_t_stop
          done
          _t_i=$((_t_j + 1)) ;;
        'for '*)
          _tpl_end $((_t_i + 1)) "$_t_end" || return 1
          _t_j=$_TPL_J
          [[ $_t_t =~ ^for[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+in[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)$ ]] \
            || { echo "$_TPL_NAME: bad tag {% $_t_t %}" >&2; return 1; }
          _t_name=${BASH_REMATCH[1]}
          local -n _t_arr=${BASH_REMATCH[2]}
          for _t_val in "${_t_arr[@]}"; do
            printf -v "$_t_name" '%s' "$_t_val"
            _tpl_block $((_t_i + 1)) "$_t_j" || return 1
          done
          unset -n _t_arr
          _t_i=$((_t_j + 1)) ;;
        'include '*)
          ( tpl_render "${_t_t#include }" ) || return 1
          _t_i=$((_t_i + 1)) ;;
        *) echo "$_TPL_NAME: line $((_t_i + 1)): unknown tag {% $_t_t %}" >&2; return 1 ;;
      esac
      continue
    fi
    # {{ var }} substitution
    _t_out='' _t_rest=$_t_line
    while [[ $_t_rest =~ \{\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}\} ]]; do
      _t_name=${BASH_REMATCH[1]}
      [[ -v $_t_name ]] || { echo "$_TPL_NAME: line $((_t_i + 1)): variable '$_t_name' is not set" >&2; return 1; }
      _t_out+=${_t_rest%%"${BASH_REMATCH[0]}"*}${!_t_name}
      _t_rest=${_t_rest#*"${BASH_REMATCH[0]}"}
    done
    printf '%s\n' "$_t_out$_t_rest"
    _t_i=$((_t_i + 1))
  done
}
