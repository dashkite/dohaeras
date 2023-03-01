import Crypto from "node:crypto"

import * as Meta from "@dashkite/joy/metaclass"
import * as Time from "@dashkite/joy/time"
import * as Val from "@dashkite/joy/value"

import * as Sublime from "@dashkite/maeve/sublime"
import * as CacheControl from "cache-control-parser"
import { Accept } from "@dashkite/media-type"

import { LRUCache } from "@dashkite/lru-cache"

import {
  createTable
  updateTimeToLive
  getTable
  deleteTable

  deleteItem
  updateItem
  query
  executeStatement
} from "@dashkite/dolores/dynamodb"

import description from "./cached-table"

# in-memory cache
cache = new LRUCache

# a version of `first` that operates on async iterators
# TODO add this to joy with specializations
first = ( it ) -> 
  for await value from it
    return value

# Timestamp encapsulates functions for dealing with timestamps / aging

Timestamp =

  # current timestamp in seconds
  now: -> Math.round Date.now() / 1000

  # given a response, return the max-age in seconds or undefined
  maxAge: ( response ) ->
    if ( header = Response.Headers.get response, "cache-control" )?
      directive = CacheControl.parse header
      directive[ "s-maxage" ] ? directive[ "max-age" ]

  # now + max-age = expiration timestamp
  from: ( response ) ->
    if ( seconds = Timestamp.maxAge response )?
      Timestamp.now() + seconds

  # predicate: true if the entry has not expired
  # negation of expired
  current: ( item ) -> !( Timestamp.expired item )

  # predicate: true if the entry HAS expired
  # negation of current
  expired: ( item ) ->
    item.expires? && ( item.expires <= Timestamp.now() )

  # compute the age of an entry based on the entry timestamp
  age: ( entry ) ->
    Timestamp.now() - entry.timestamp

# Select functions encapsulate DynamoDB queries for us
Select =

  # get an entry based on a key
  entry: ( table, { key, bindings }) ->
    statement = """
      select * from "#{ table }"
      where "key" = '#{ key }'
      and "bindings" = '#{ bindings }'
    """
    first await query statement

  # get all entries for a given resource class
  # that match a set of bindings
  bindings: ( table, { key }, bindings ) ->
    statement = """
      select * from "#{ table }"
      where "key" = '#{ key }'
    """
    for name, value of bindings
      statement += """
        \nand "resource"."bindings"."#{ name }" = '#{ value }'
      """
    query statement

  all: ( table ) ->
    query """
      select "key", "bindings" FROM "#{ table }"
    """

# Cache encapsulates cache helpers
Cache = 

  key: ({ key, bindings }) -> "#{ key } #{ bindings }"

# Entry encapsulates entry-related functions:

Entry =

  # key: create an entry key
  key: ( request ) ->
    { domain, resource } = request
    key = "#{ domain } #{ resource.name }"
    bindings = Hash.bindings resource.bindings
    { key, bindings }

  # get: get an entry based on a request
  get: ( table, request ) ->
    key = Entry.key request
    ckey = Cache.key key
    if ( result = cache.get ckey )?
      result
    else
      result = await Select.entry table, key
      cache.set ckey, result
      result

  # delete: delete an entry and all aliases based on a request
  # TODO optimize with batch execute?
  delete: ( table, request ) ->
    key = Entry.key request
    entries = await Select.bindings table, key, request.resource.bindings
    for await { key, bindings, aliases } from entries
      cache.delete Cache.key { key, bindings }
      await deleteItem table, { key, bindings }
      for alias in aliases
        _key = Entry.key alias
        cache.delete Cache.key _key
        await deleteItem table, _key

# Normalize functions for decoding headers
# when necessary, usually as part of canonicalization

Normalize =
  
  accept: Accept.parse

  vary: ( value ) ->
    ( value
        ?.split ","
        .map ( text ) -> text.trim() 
    ) ? []
    


# Hash functions encapsulate hashing various parts of an HTTP
# request/response:

Hash =

  # from: generate a Base64 encoded MD5 hash based on a value
  from: ( value ) ->
    Crypto
      .createHash "md5"
      .update JSON.stringify value
      .digest "base64"

  # bindings: hash resource bindings
  bindings: ( bindings = {} ) ->
    Hash.from (
      Object
        .keys bindings
        .sort()
        .map ( key ) -> [ key, bindings[ key ] ]
    )

  # vary: generate a hash of the request based on the response vary header
  vary: ( vary, request ) ->
    Hash.from (
      vary
        .sort()
        .map ( header ) -> 
          [ 
            header
            Request.Headers.get request, header
          ]
    )

  # response: generate a hash of the response content
  response: ( response ) ->
    Hash.from [ response.content ]


# Request encapsulates helper functions for dealing with requests

Request =

  Headers:

    # get a normalized version of a given header
    # TODO does this belong in Sublime?
    get: ( request, header ) ->
      if ( text = Sublime.Request.Headers.get request, header )?
        ( Normalize[ header ]? text  ) ? text

# Response encapsulates helper functions for dealing with responses

Response =

  Headers:
    # get a normalized version of a given header
    # TODO does this belong in Sublime?
    get: ( response, header ) ->
      if ( text = Sublime.Response.Headers.get response, header )?
        ( Normalize[ header ]? text  ) ? text

  # is a response cacheable?
  cacheable: ( response ) ->
    !( "*" in Response.vary response )
  
  # get the vary header (returns an array of header names)
  vary: ( response ) ->
    ( Response.Headers.get response, "vary" ) ? []

  aliases: ( response ) ->
    if ( links = response.headers?.link )?
      links
        .filter ( link ) -> link.parameters.rel == "alias"
        .map ({ resource }) -> resource
    else []
      
  # set the response age header based on a cache entry
  age: ( response, entry ) ->
    response.headers ?= {}
    response.headers.age = [ Timestamp.age entry ]
    response

# The Client class encapsualtes the API we expose

class Client

  Meta.mixin @::, [
    Meta.getters

      # the name of the main cache table
      table: -> "dracarys-#{ @name }"
  
  ]

  @create: ( name ) -> Object.assign ( new @ ), { name }

  # deploy the infrastructure for a cache
  # you wouldn't typically use this
  deploy: ->

    await createTable { 
      TableName: @table
      description... 
    }

    # give it a minute...
    await Time.sleep 5000

    await updateTimeToLive {
      TableName: @table
      TimeToLiveSpecification:
        AttributeName: "expires"
        Enabled: true
    }

  # is the cache available?
  status: ->
    if ( table = await getTable @table )?
      if table.TableStatus == "ACTIVE"
        "ready"
      else
        "not ready"
    else
      "not found"
  
  # remove the infrastructure associated with a cache
  # you wouldn't typically use this
  undeploy: -> deleteTable @table

  # empty the cache
  clear: ->
    for await { key, bindings } from await Select.all @table
      await deleteItem @table, { key, bindings }

  # get a cache entry based on a request
  get: ( request ) ->
    if ( entry = await Entry.get @table, request )?
      if Timestamp.current entry
        hash = Hash.vary entry.vary, request
        variant = entry.responses[ entry.requests[ hash ]]
        Response.age variant.response, entry
      else
        @delete request
        undefined


  # check to see whether a cache entry exists
  has: ( request ) -> ( await @get request )?

  # add a request/response pair to the cache
  put: ( request, response ) ->

    return unless Response.cacheable response

    { resource } = request
    aliases = Response.aliases response
    responses = {}
    requests = {}

    # per the spec, the vary header should always be the same
    # for a given resource (URL) - MDN, but can't find source
    vary = Response.vary response

    # update timestamp/expiration
    timestamp = Timestamp.now()
    expires = Timestamp.from response

    if ( entry = await Entry.get @table, request )?

      # rebuild the dictionaries based on the current response
      for variant in Object.values entry.responses
        hash = Hash.response variant.response
        requests[ Hash.vary vary, variant.request ] = hash
        responses[ hash ] = variant

    # add in the current variant
    hash = Hash.response response
    requests[ Hash.vary vary, request ] = hash
    responses[ hash ] = { request, response }

    await updateItem @table, ( Entry.key request ),
      { resource, vary, aliases, expires, timestamp, requests, responses }
    
    # return the response, mostly so we don't return the result of the AWS call
    # :)
    response

  # delete an entry (and all it's aliases)
  delete: ( request ) -> Entry.delete @table, request
      
export { Client }