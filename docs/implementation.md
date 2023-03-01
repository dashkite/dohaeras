# Implementation Guide

*Dracarys*

Dracarys implements an HTTP cache. It supports three main functions: get, put, and delete. Delete supports sophisticated invalidations, necessary for use with real-world APIs.

## Design Goals

### Invalidations

The API is based on a semantic representation of an HTTP request-response pair. In particular, resources are represented using *resource descriptions* rather than URLs. The sementic representation of a resource allows us to support targeted, or wildcard, validations, beyond what is typically possible in CDNs, which rely on text matching against the URL.

How the URL is decoded into this form is left to the client: we handle this using URL templates specified in the API description based on the URL Codex format. We could support this within Dracarys itself, which would make it more general purpose, but since we use this approach throughout our applications, we assume this decoding has already been done prior to invoking Dracarys.

### Aliases

Dracarys also supports resources *aliases*—alternative descriptions for the same resource—and invalidation of aliases along with a given resource. A typical scenario for aliases is a query interface that returns a resource that has a canonical URL.

For example, we might have a query interface that allows us to find an account by email, but the account has a canonical URL using the account address. When we update the account resource, we need to ensure that we invalidate _both_ the response associated with the canonical URL and the version cached via the query URL.

As with decoding the URL, identifying the aliases is left to the client.

### Vary Support

Dracarys supports the `vary` header to distinguish between different representations of a resource. Each time a value is `put` to the cache, we recompute this hash for each cached response. Per the specification, responses should always return the same `vary` header. Thus, if it changes, we treat that as a change in the caching policy for that resource.

## Terminology

### Alias

An *alias* is a resource description for the same logical resource. The same resource may be accessed by two different URLs: we refer to such resources as aliases.

### Entry

An *entry* is a cache entry. It consists of: a resource description, a representation of the vary header, a variant dictionary, a content dictionary, a list of aliases, a timestamp, and an expiry.

### Variant

A *variant* is a request-response pair.

## Implementation

To store a cache entry, we start with the `vary` header. We treat the `vary` header as specification for a hash of the request. The header is canonicalized and each header value added to an array of values to be hashed. 

We also compute a hash of the response, based on its content. The request and response are now addressable, so we can place them in dictionaries, ensuring that we don’t store redundant variants. The request dictionary allows us to go from a request hash to a response hash. The response dictionary allows us to go from a response hash to a variant. Together, given an entry, and a request and response, we can quickly find the corresponding variant:

​	*request-hash → response-hash → variant*

The entry properies are described below.

|        Name | Description                                                  | Purpose                                                      |
| ----------: | ------------------------------------------------------------ | :----------------------------------------------------------- |
|  `resource` | The resource description corresponding to the cache entry.   | Query bindings for invalidations.                            |
|      `vary` | The normalized representation of the `vary` header associated with the resource. | (Re-)computing request hashes for variants.                  |
|   `aliases` | A list of resource descriptions which are aliases for the resource. | Invalidating aliases.                                        |
|   `expires` | A timestamp indicating when the entry expires.               | Detection and automatic removal of expired entries.          |
| `timestamp` | The timestamp for the entry itself (basically, the last update time in epoch seconds). | Convenience for computing `max-age` and updating `expires`.  |
|  `requests` | The map of request hashes to response hashes.                | Allows fast lookups based on the request hash and ensures that each variant is stored only once, using the most recent response `vary` header. |
| `responses` | The map of response hashes to variants.                      | Allows fast lookups based on the response hash (obtained from the `hashes` map) and ensures each response is stored only once. |

### Put

The `put` method is the most involved. Broadly speaking, there are three steps:

1. Initialization
2. (Re-)computing the dictionaries
3. Storing the entry

#### Initialization

```coffeescript
return unless Response.cacheable response

{ resource } = request
aliases = response.aliases ? []
responses = {}
requests = {}

# per the spec, the vary header should always be the same
# for a given resource (URL) - MDN, but can't find source
vary = Response.vary response

# update timestamp/expiration
timestamp = Timestamp.now()
expires = Timestamp.from response
```

1. Check to make sure the response is cacheable.
2. Initialize the aliases based on the response.
3. Initialize the `requests` and `responses` maps to empty because we always build them from scratch.
4. Initialize the normalized `vary`  header that we’ll associate with the entry.
5. Initialize the timestamp and expiration.

#### (Re-)computing the dictionaries

```coffeescript
if ( entry = await Entry.get @table, request )?

  # rebuild the dictionaries based on the current response
  for variant in Object.values entry.responses
    hash = Hash.response variant.response
    requests[ Hash.vary vary, variant.request ] = hash
    responses[ hash ] = variant
```

1. If an entry already exists, we rebuild the `requests` and `responses` hashes.
2. For each variant in the response hash…
3. Hash the response again.
4. Hash the request and use that as the entry in the `requests` map.
5. Use the response hash to put the entry in `responses` map.

Together, steps (4) and (5) create the mapping from the request to the response based on the vary header.

We still need to add the current request and response pair.

```coffeescript
# add in the current variant
hash = Hash.response response
requests[ Hash.vary vary, request ] = hash
responses[ hash ] = { request, response }
```

We don’t need to check if we already have this variant because, thanks to our use of hashing, we’ll just overwrite it if we do. We prefer the most recent response in any event.

#### Storing The Entry

The final step is to simply write the new or updated entry to the cache table:

```coffeescript
await updateItem @table, ( Entry.key request ),
	{ resource, vary, aliases, expires, timestamp, requests, responses }
```

### Get

Now that we can see how an entry is created or updated, it’s easy to see how we retrieve a response:

```coffeescript
if ( entry = await Entry.get @table, request )?
	if Timestamp.current entry
		hash = Hash.vary entry.vary, request
		variant = entry.responses[ entry.requests[ hash ]]
		Response.age variant.response, entry
```

1. If an entry exists and it’s current, hash the request using the entry’s `vary` property.
2. Use the request hash to obtain a response hash from the requests map.
3. Use the response hash to obtain the variant from responses map.
4. Update the age of the variant’s `response` object and return it.

### Delete

Recall that one of our design goals is to support cache invalidation. Our `delete` method reflect that. Unlike in `get` and `put` we do not assume that the resource bindings of the request fully specify a resource. Instead, we assume that it may specify a number of resources. Thus, we construct a query against the `resource` property of the entry. Like the `vary` property, we may assume that all the variants of a given entry refer to the same resource. Thus, we can store the resource as a top-level property and query it. In addition, for each entry we match, we delete all of its aliases, if any.

```coffeescript
{ key } = Entry.key request
entries = await Select.bindings table, key, request.resource.bindings
for await { key, bindings, aliases } from entries
	await deleteItem table, { key, bindings }
  for alias in aliases
  	await deleteItem table, Entry.key alias
```

1. Select all matching entries for the given set of bindings and resource key.
2. For each entry, delete the entry.
3. For each entry alias, delete the entry.
