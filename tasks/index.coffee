import FS from "node:fs/promises"

import * as t from "@dashkite/genie"
import preset from "@dashkite/genie-presets"
import sky from "@dashkite/sky-presets"

import {
  createTable
  updateTimeToLive 
  deleteTable
  query
  deleteItem
} from "@dashkite/dolores/dynamodb"

import YAML from "js-yaml"

preset t

# TODO how to invoke client? need to build first
# or package as genie presets (since you wouldn't
# usually need to run these here)

# t.define "dracarys:create", ( name ) ->

# t.define "dracarys:delete", ( name ) ->

# t.define "dracarys:clear", ( name ) ->
