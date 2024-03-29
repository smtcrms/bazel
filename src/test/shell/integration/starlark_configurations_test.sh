#!/bin/bash
#
# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# starlark_configuration_test.sh: integration tests for starlark build configurations

# --- begin runfiles.bash initialization ---
# Copy-pasted from Bazel's Bash runfiles library (tools/bash/runfiles/runfiles.bash).
set -euo pipefail
if [[ ! -d "${RUNFILES_DIR:-/dev/null}" && ! -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  if [[ -f "$0.runfiles_manifest" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
  elif [[ -f "$0.runfiles/MANIFEST" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
  elif [[ -f "$0.runfiles/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
    export RUNFILES_DIR="$0.runfiles"
  fi
fi
if [[ -f "${RUNFILES_DIR:-/dev/null}/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
  source "${RUNFILES_DIR}/bazel_tools/tools/bash/runfiles/runfiles.bash"
elif [[ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  source "$(grep -m1 "^bazel_tools/tools/bash/runfiles/runfiles.bash " \
            "$RUNFILES_MANIFEST_FILE" | cut -d ' ' -f 2-)"
else
  echo >&2 "ERROR: cannot find @bazel_tools//tools/bash/runfiles:runfiles.bash"
  exit 1
fi
# --- end runfiles.bash initialization ---

source "$(rlocation "io_bazel/src/test/shell/integration_test_setup.sh")" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }

case "$(uname -s | tr [:upper:] [:lower:])" in
msys*|mingw*|cygwin*)
  declare -r is_windows=true
  ;;
*)
  declare -r is_windows=false
  ;;
esac

if "$is_windows"; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL="*"
fi

add_to_bazelrc "build --package_path=%workspace%"

#### HELPER FXNS #######################################################

function write_build_setting_bzl() {
 cat > $pkg/build_setting.bzl <<EOF
BuildSettingInfo = provider(fields = ['name', 'value'])

def _build_setting_impl(ctx):
  return [BuildSettingInfo(name = ctx.attr.name, value = ctx.build_setting_value)]

drink_attribute = rule(
  implementation = _build_setting_impl,
  build_setting = config.string(flag = True),
)
EOF

  cat > $pkg/rules.bzl <<EOF
load("//$pkg:build_setting.bzl", "BuildSettingInfo")

def _impl(ctx):
  _type_name = ctx.attr._type[BuildSettingInfo].name
  _type_setting = ctx.attr._type[BuildSettingInfo].value
  print(_type_name + "=" + str(_type_setting))
  _temp_name = ctx.attr._temp[BuildSettingInfo].name
  _temp_setting = ctx.attr._temp[BuildSettingInfo].value
  print(_temp_name + "=" + str(_temp_setting))
  print("strict_java_deps=" + ctx.fragments.java.strict_java_deps)

drink = rule(
  implementation = _impl,
  attrs = {
    "_type":attr.label(default = Label("//$pkg:type")),
    "_temp":attr.label(default = Label("//$pkg:temp")),
  },
  fragments = ["java"],
)
EOF

  cat > $pkg/BUILD <<EOF
load("//$pkg:build_setting.bzl", "drink_attribute")
load("//$pkg:rules.bzl", "drink")

drink(name = 'my_drink')

drink_attribute(name = 'type', build_setting_default = 'unknown')
drink_attribute(name = 'temp', build_setting_default = 'unknown')
EOF
}

#### TESTS #############################################################

function test_default_flag() {
 local -r pkg=$FUNCNAME
 mkdir -p $pkg

  write_build_setting_bzl

  bazel build //$pkg:my_drink --experimental_build_setting_api > output \
    2>"$TEST_log" || fail "Expected success"

  expect_log "type=unknown"
}

function test_set_flag() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  write_build_setting_bzl

  bazel build //$pkg:my_drink --//$pkg:type="coffee" \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"

  expect_log "type=coffee"
}

function test_starlark_and_native_flag() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  write_build_setting_bzl

  bazel build //$pkg:my_drink --//$pkg:type=coffee --strict_java_deps=off \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"

  expect_log "type=coffee"
  expect_log "strict_java_deps=off"
}

function test_dont_parse_flags_after_dash_dash() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  write_build_setting_bzl

  bazel build //$pkg:my_drink --//$pkg:type=coffee \
    --experimental_build_setting_api -- --//$pkg:temp=iced \
     > output 2>"$TEST_log" \
    && fail "Expected failure"

  expect_log "invalid package name '-//test_dont_parse_flags_after_dash_dash'"
}

function test_doesnt_work_without_experimental_flag() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  write_build_setting_bzl

  bazel build //$pkg:my_drink --//$pkg:type=coffee > output 2>"$TEST_log" \
    && fail "Expected failure"

  expect_log "Error loading option //$pkg:type:"
  expect_log "Extension file '$pkg/build_setting.bzl' has errors"
}

function test_multiple_starlark_flags() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  write_build_setting_bzl

  bazel build //$pkg:my_drink --//$pkg:type="coffee" --//$pkg:temp="iced" \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"

  expect_log "type=coffee"
  expect_log "temp=iced"

  # Ensure that order doesn't matter.
  bazel build //$pkg:my_drink --//$pkg:temp="iced" --//$pkg:type="coffee" \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"

  expect_log "type=coffee"
  expect_log "temp=iced"
}

function test_flag_default_change() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  write_build_setting_bzl

  bazel build //$pkg:my_drink --experimental_build_setting_api > output \
    2>"$TEST_log" || fail "Expected success"

  expect_log "type=unknown"

  cat > $pkg/BUILD <<EOF
load("//$pkg:build_setting.bzl", "drink_attribute")
load("//$pkg:rules.bzl", "drink")

drink(name = 'my_drink')

drink_attribute(name = 'type', build_setting_default = 'cowabunga')
drink_attribute(name = 'temp', build_setting_default = 'cowabunga')
EOF

  bazel build //$pkg:my_drink --experimental_build_setting_api > output \
    2>"$TEST_log" || fail "Expected success"

  expect_log "type=cowabunga"
}

# Regression tests for b/134580627
# Make sure package incrementality works during options parsing
function test_incremental_delete_build_setting() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  cat > $pkg/rules.bzl <<EOF
def _impl(ctx):
  return []

my_flag = rule(
  implementation = _impl,
  build_setting = config.string(flag = True)
)
simple_rule = rule(implementation = _impl)
EOF

  cat > $pkg/BUILD <<EOF
load("//$pkg:rules.bzl", "my_flag", "simple_rule")

my_flag(name = "my_flag", build_setting_default = "default")
simple_rule(name = "simple_rule")
EOF

  bazel build //$pkg:simple_rule --//$pkg:my_flag=cowabunga \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"

  cat > $pkg/BUILD <<EOF
load("//$pkg:rules.bzl", "simple_rule")

simple_rule(name = "simple_rule")
EOF

  bazel build //$pkg:simple_rule --//$pkg:my_flag=cowabunga \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    && fail "Expected failure" || true

  expect_log "no such target '//$pkg:my_flag'"
}

#############################

function test_incremental_delete_build_setting_in_different_package() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  cat > $pkg/rules.bzl <<EOF
def _impl(ctx):
  return []

my_flag = rule(
  implementation = _impl,
  build_setting = config.string(flag = True)
)
simple_rule = rule(implementation = _impl)
EOF

  cat > $pkg/BUILD <<EOF
load("//$pkg:rules.bzl", "my_flag")
my_flag(name = "my_flag", build_setting_default = "default")
EOF

  mkdir -p pkg2

  cat > pkg2/BUILD <<EOF
load("//$pkg:rules.bzl", "simple_rule")
simple_rule(name = "simple_rule")
EOF

  bazel build //pkg2:simple_rule --//$pkg:my_flag=cowabunga \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"

  cat > $pkg/BUILD <<EOF
EOF

  bazel build //pkg2:simple_rule --//$pkg:my_flag=cowabunga \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    && fail "Expected failure" || true

  expect_log "no such target '//$pkg:my_flag'"
}

#############################


function test_incremental_add_build_setting() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  cat > $pkg/rules.bzl <<EOF
def _impl(ctx):
  return []

my_flag = rule(
  implementation = _impl,
  build_setting = config.string(flag = True)
)
simple_rule = rule(implementation = _impl)
EOF

  cat > $pkg/BUILD <<EOF
load("//$pkg:rules.bzl", "simple_rule")

simple_rule(name = "simple_rule")
EOF

  bazel build //$pkg:simple_rule --experimental_build_setting_api \
    > output 2>"$TEST_log" || fail "Expected success"

  cat > $pkg/BUILD <<EOF
load("//$pkg:rules.bzl", "my_flag", "simple_rule")

my_flag(name = "my_flag", build_setting_default = "default")
simple_rule(name = "simple_rule")
EOF

  bazel build //$pkg:simple_rule --//$pkg:my_flag=cowabunga \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"
}

function test_incremental_change_build_setting() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  cat > $pkg/rules.bzl <<EOF
MyProvider = provider(fields = ["value"])

def _flag_impl(ctx):
  return MyProvider(value = ctx.build_setting_value)

my_flag = rule(
  implementation = _flag_impl,
  build_setting = config.string(flag = True)
)

def _rule_impl(ctx):
  print("flag = " + ctx.attr.flag[MyProvider].value)

simple_rule = rule(
  implementation = _rule_impl,
  attrs = {"flag" : attr.label()}
)
EOF

  cat > $pkg/BUILD <<EOF
load("//$pkg:rules.bzl", "my_flag", "simple_rule")

my_flag(name = "my_flag", build_setting_default = "default")
simple_rule(name = "simple_rule", flag = ":my_flag")
EOF

  bazel build //$pkg:simple_rule --//$pkg:my_flag=yabadabadoo \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"

  expect_log "flag = yabadabadoo"

# update the flag to return a different value
  cat > $pkg/rules.bzl <<EOF
MyProvider = provider(fields = ["value"])

def _flag_impl(ctx):
  return MyProvider(value = "scoobydoobydoo")

my_flag = rule(
  implementation = _flag_impl,
  build_setting = config.string(flag = True)
)

def _rule_impl(ctx):
  print("flag = " + ctx.attr.flag[MyProvider].value)

simple_rule = rule(
  implementation = _rule_impl,
  attrs = {"flag" : attr.label()}
)
EOF

  bazel build //$pkg:simple_rule --//$pkg:my_flag=yabadabadoo \
    --experimental_build_setting_api > output 2>"$TEST_log" \
    || fail "Expected success"

  expect_log "flag = scoobydoobydoo"
}

# Test that label-typed build setting has access to providers of the
# target it points to.
function test_label_flag() {
  local -r pkg=$FUNCNAME
  mkdir -p $pkg

  cat > $pkg/BUILD <<EOF
load("//$pkg:rules.bzl", "my_rule", "simple_rule")

my_rule(name = "my_rule")

simple_rule(name = "default", value = "default_val")

simple_rule(name = "command_line", value = "command_line_val")

label_flag(
    name = "my_label_build_setting",
    build_setting_default = ":default"
)
EOF

  cat > $pkg/rules.bzl <<EOF
def _impl(ctx):
    _setting = ctx.attr._label_flag[SimpleRuleInfo].value
    print("value=" + _setting)

my_rule = rule(
    implementation = _impl,
    attrs = {
        "_label_flag": attr.label(default = Label("//$pkg:my_label_build_setting")),
    },
)

SimpleRuleInfo = provider(fields = ['value'])

def _simple_rule_impl(ctx):
    return [SimpleRuleInfo(value = ctx.attr.value)]

simple_rule = rule(
    implementation = _simple_rule_impl,
    attrs = {
        "value":attr.string(),
    },
)
EOF

  bazel build //$pkg:my_rule > output 2>"$TEST_log" || fail "Expected success"

  expect_log "value=default_val"

  bazel build //$pkg:my_rule --//$pkg:my_label_build_setting=//$pkg:command_line > output \
    2>"$TEST_log" || fail "Expected success"

  expect_log "value=command_line_val"
}

run_suite "${PRODUCT_NAME} starlark configurations tests"
