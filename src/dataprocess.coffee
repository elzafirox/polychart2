###
Wrapper around the data processing piece that keeps track of the kind of
data processing to be done.
###
class DataProcess
  ## save the specs
  constructor: (layerSpec, grouping, strictmode) ->
    @dataObj = layerSpec.data
    @initialSpec = poly.parser.layerToData layerSpec, grouping
    @prevSpec = null
    @strictmode = strictmode
    @statData = null
    @metaData = {}

  reset : (callback) -> @make @initialSpec, callback

  ## calculate things...
  make : (spec, grouping, callback) ->
    wrappedCallback = @_wrap callback
    if @strictmode
      wrappedCallback @dataObj.json, {}
    if @dataObj.computeBackend
      dataSpec = poly.parser.layerToData spec, grouping
      backendProcess(dataSpec, @dataObj, wrappedCallback)
    else
      dataSpec = poly.parser.layerToData spec, grouping
      @dataObj.getData (data) ->
        frontendProcess(dataSpec, data, wrappedCallback)

  _wrap : (callback) => (params) =>
    # save a copy of the data/meta before going to callback
    {data, meta} = params
    @statData = data
    @metaData = meta
    callback @statData, @metaData

poly.DataProcess = DataProcess

###
Temporary
###
poly.data.process = (dataObj, layerSpec, strictmode, callback) ->
  d = new DataProcess layerSpec, strictmode
  d.process callback
  d

###
TRANSFORMS
----------
Key:value pair of available transformations to a function that creates that
transformation. Also, a metadata description of the transformation is returned
when appropriate. (e.g for binning)
###
transforms =
  'bin' : (key, transSpec, meta) ->
    {name, binwidth} = transSpec
    if meta.type is 'num'
      if isNaN(binwidth)
        throw poly.error.defn "The binwidth #{binwidth} is invalid for a numeric varliable"
      binwidth = +binwidth
      binFn = (item) ->
        item[name] = binwidth * Math.floor item[key]/binwidth
      return trans: binFn, meta: {bw: binwidth, binned: true, type:'num'}
    if meta.type is 'date'
      if not (binwidth in poly.const.timerange)
        throw poly.error.defn "The binwidth #{binwidth} is invalid for a datetime varliable"
      binFn = (item) ->
        if binwidth is 'week'
          item[name] = moment.unix(item[key]).day(0).unix()
        else if binwidth is 'decade'
          m = moment.unix(item[key]).startOf('year')
          m.year 10 * Math.floor(m.year()/10)
          item[name] = m.unix()
        else
          item[name] = moment.unix(item[key]).startOf(binwidth).unix()
      return trans: binFn, meta: {bw: binwidth, binned: true, type:'date'}
  'lag' : (key, transSpec, meta) ->
    {name, lag} = transSpec
    lastn = (undefined for i in [1..lag])
    lagFn = (item) ->
      lastn.push(item[key])
      item[name] = lastn.shift()
    return trans: lagFn, meta: {type: meta.type}

###
Helper function to figures out which transformation to create, then creates it
###
transformFactory = (key, transSpec, meta) ->
  transforms[transSpec.trans](key, transSpec, meta ? {})

###
FILTERS
----------
Key:value pair of available filtering operations to filtering function. The
filtering function returns true iff the data item satisfies the filtering
criteria.
###
filters =
  'lt' : (x, value) -> x < value
  'le' : (x, value) -> x <= value
  'gt' : (x, value) -> x > value
  'ge' : (x, value) -> x >= value
  'in' : (x, value) -> x in value

###
Helper function to figures out which filter to create, then creates it
###
filterFactory = (filterSpec) ->
  filterFuncs = []
  _.each filterSpec, (spec, key) ->
    _.each spec, (value, predicate) ->
      filter = (item) -> filters[predicate](item[key], value)
      filterFuncs.push filter
  (item) ->
    for f in filterFuncs
      if not f(item) then return false
    return true

###
STATISTICS
----------
Key:value pair of available statistics operations to a function that creates
the appropriate statistical function given the spec. Each statistics function
produces one atomic value for each group of data.
###
statistics =
  sum : (spec) -> (values) -> _.reduce(_.without(values, undefined, null),
                                                 ((v, m) -> v + m), 0)
  mean: (spec) -> (values) ->
    values = _.without(values, undefined, null)
    return _.reduce(values, ((v, m) -> v + m), 0) / values.length
  count : (spec) -> (values) -> _.without(values, undefined, null).length
  unique : (spec) -> (values) -> (_.uniq(_.without(values, undefined, null))).length
  min: (spec) -> (values) -> _.min(values)
  max: (spec) -> (values) -> _.max(values)
  median: (spec) -> (values) -> poly.median(values)
  box: (spec) -> (values) ->
    len = values.length
    if len > 5
      mid = len/2
      sortedValues = _.sortBy(values, (x)->x)
      quarter = Math.ceil(mid)/2
      if quarter % 1 != 0
          quarter = Math.floor(quarter)
          q2 = sortedValues[quarter]
          q4 = sortedValues[(len-1)-quarter]
      else
          q2 = (sortedValues[quarter] + sortedValues[quarter-1])/2
          q4 = (sortedValues[len-quarter] + sortedValues[(len-quarter)-1])/2
      iqr = q4-q2
      lowerBound = q2-(1.5*iqr)
      upperBound = q4+(1.5*iqr)
      splitValues = _.groupBy(sortedValues,
                              (v) -> v >= lowerBound and v <= upperBound)
      return {
        q1: _.min(splitValues.true)
        q2: q2
        q3: poly.median(sortedValues, true)
        q4: q4
        q5: _.max(splitValues.true)
        outliers: splitValues.false ? []
      }
    return {
      outliers: values
    }
###
Helper function to figures out which statistics to create, then creates it
###
statsFactory = (statSpec) ->
  statistics[statSpec.stat](statSpec)

###
Calculate statistics
###
calculateStats = (data, statSpecs) ->
  # define stat functions
  statFuncs = {}
  _.each statSpecs.stats, (statSpec) ->
    {key, name} = statSpec
    statFn = statsFactory statSpec
    statFuncs[name] = (data) -> statFn _.pluck(data, key)
  # calculate the statistics for each group
  groupedData = poly.groupBy data, statSpecs.groups
  _.map groupedData, (data) ->
    rep = {}
    _.each statSpecs.groups, (g) -> rep[g] = data[0][g] # define a representative
    _.each statFuncs, (stats, name) -> rep[name] = stats(data) # calc stats
    return rep

###
META
----
Calculations of meta properties including sorting and limiting based on the
values of statistical calculations
###
calculateMeta = (key, metaSpec, data) ->
  {sort, stat, limit, asc} = metaSpec
  # group the data by the key
  if stat
    statSpec = stats: [stat], groups: [key]
    data = calculateStats(data, statSpec)
  # sorting
  multiplier = if asc then 1 else -1
  comparator = (a, b) ->
    if a[sort] == b[sort] then return 0
    if a[sort] >= b[sort] then return 1 * multiplier
    return -1 * multiplier
  data.sort comparator
  # limiting
  if limit
    data = data[0..limit-1]
  values = _.uniq _.pluck data, key
  return meta: { levels: values, sorted: true}, filter: { in: values}

###
GENERAL PROCESSING
------------------
Coordinating the actual work being done
###

###
Perform the necessary computation in the front end
###
frontendProcess = (dataSpec, data, callback) ->
  metaData = _.clone(data.meta)
  data = _.clone(data.raw)
  # metaData and related f'ns
  metaData ?= {}
  addMeta = (key, meta) ->  metaData[key] = _.extend (metaData[key] ? {}), meta
  # transforms
  if dataSpec.trans
    for transSpec in dataSpec.trans
      {key} = transSpec
      {trans, meta} = transformFactory(key, transSpec, metaData[key])
      for d in data
        trans(d)
      addMeta transSpec.name, meta
  # filter
  if dataSpec.filter
    data = _.filter data, filterFactory(dataSpec.filter)
  # meta + more filtering
  if dataSpec.meta
    additionalFilter = {}
    for key, metaSpec of dataSpec.meta
      {meta, filter} = calculateMeta(key, metaSpec, data)
      additionalFilter[key] = filter
      addMeta key, meta
    data = _.filter data, filterFactory(additionalFilter)
  # stats
  if dataSpec.stats and dataSpec.stats.stats and dataSpec.stats.stats.length > 0
    data = calculateStats(data, dataSpec.stats)
    for statSpec in dataSpec.stats.stats
      {name} = statSpec
      addMeta name, {type: 'num'}
  # select: make sure everything selected is there
  for key in dataSpec.select ? []
    if not metaData[key]?
      throw poly.error.defn ("You referenced a data column #{key} that doesn't exist.")
  # done
  callback(data:data, meta:metaData)

###
Perform the necessary computation in the backend
###
backendProcess = (dataSpec, dataObj, callback) ->
  dataObj.getData callback, dataSpec

###
For debug purposes only
###
poly.data.frontendProcess = frontendProcess
