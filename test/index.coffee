import { test, success } from "@dashkite/amen"
import { print, debug } from "@dashkite/amen-console"
import assert from "@dashkite/assert"

import { sleep } from "@dashkite/joy"

import * as k from "@dashkite/katana"
import * as m from "@dashkite/mimic"
import browse from "@dashkite/genie-presets/browser"

do browse ({browser, port}) ->

  # just give it a minute in case files haven't been written out yet
  await sleep 1000

  print await test "Tests", [

    await do m.launch browser, [
      m.page
      m.goto "http://localhost:#{port}/"
      m.waitFor -> window.__test?
      m.evaluate -> window.__test
      k.get
    ]

  ]

  process.exit if success then 0 else 1



# import * as Type from "@dashkite/joy/type"
# import * as Time from "@dashkite/joy/time"

# # MUT
# import * as Dracarys from "../src"
# import scenarios from "./scenarios"

# client = Dracarys.Client.create "test"

# assertAge = ( result ) ->
#   assert result.headers.age?[0]?
#   assert result.headers.age[0] >= 0
#   delete result.headers.age

# invalidate = ({

#     cache
#     invalidate
#     removed
#     remain

#   }) -> ->
    
#     for { request, response } in cache
#       await client.put request, response
    
#     await client.delete invalidate

#     for request in removed
#       response = await client.get request
#       assert !( response? )

#     for { request, response } in remain
#       result = await client.get request
#       assertAge result
#       assert.deepEqual response, result

#     # reset for next test
#     await client.clear()

# do ->

#   print await test "Dracarys", [

#     test "Create"

#     # await test "Create", ->
#     #   await client.deploy()
#     #   loop
#     #     status = await client.status()
#     #     break if status == "ready"

#     await test "Basic Caching", [
      
#       await test "Put", ->
#         { request, response } = scenarios.basic
#         await client.put request, response

#       await test "Get", ->
#         { request, response } = scenarios.basic
#         result = await client.get request
#         assert result?
#         assertAge result
#         assert.deepEqual result, response

#       await test "Has", ->
#         { request, response } = scenarios.basic
#         result = await client.has request
#         assert result

#       await test "Delete", ->
#         { request, response } = scenarios.basic
#         await client.delete request
#         result = await client.get request
#         assert !( result? )

#       await test "Clear", ->
#         await client.clear()

#     ]

#     await test "Expiration", [

#       await test "Max Age", wait: false, ->
#         { request, response } = scenarios.basic
#         await client.put request, response
#         result = await client.get request
#         assert result?
#         assertAge result
#         assert.deepEqual result, response

#         # wait for expiration
#         console.log "letting the cache expire..."
#         await Time.sleep 2000
#         result = await client.get request
#         assert !( result? )

#     ]

#     await test "Invalidation", [
      
#       await test "Targeted", invalidate scenarios.invalidation.targeted
#       await test "Wildcard", invalidate scenarios.invalidation.wildcard
#       await test "Alias", invalidate scenarios.invalidation.alias

#     ]

#     test "Delete"

#     # test "Delete", ->
#     #   await client.undeploy()

#   ]
