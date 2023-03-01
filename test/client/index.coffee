import assert from "@dashkite/assert"
import { test } from "@dashkite/amen"

do ->

  window.__test = await do ->

    test "In-Browser Tests", [
      test "hello world", ->
        cache = await caches.open "dohaeras"
        await cache.add new Request "https://db.dashkite.io"
        console.log await cache.match new Request "https://db.dashkite.io"

    ]
