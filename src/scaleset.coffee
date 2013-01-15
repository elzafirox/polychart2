poly.scaleset = (guideSpec, domains, ranges) ->
  return new ScaleSet(guideSpec, domains, ranges)

class ScaleSet
  constructor: (tmpRanges, coord) ->
    # note that axes.x is the axis for the x-aesthetic. it may or ma NOT be
    # the x-axis displayed on the screen.
    @coord = coord
    @ranges = tmpRanges
    @axes = {}
    @legends = []
    @deletedAxes = []
    @deletedLegends = []

  make: (guideSpec, domains, layers) ->
    @guideSpec = guideSpec
    @layers = layers
    @domains = domains
    @domainx = @domains.x
    @domainy = @domains.y
    @scales = @_makeScales(guideSpec, domains, @ranges)
    @reverse=
      x: @scales.x.finv
      y: @scales.y.finv
    @layerMapping = @_mapLayers layers

  setRanges: (ranges) ->
    @ranges = ranges
    @_makeXScale()
    @_makeYScale()
  setXDomain: (d) ->
    @domainx = d
    @_makeXScale()
  setYDomain: (d) ->
    @domainy = d
    @_makeYScale()
  resetDomains: () ->
    @domainx = @domains.x
    @domainy = @domains.y
    @_makeXScale()
    @_makeYScale()
  _makeXScale: () -> @scales.x.make @domainx, @ranges.x, @getSpec('x').padding
  _makeYScale: () -> @scales.y.make @domainy, @ranges.y, @getSpec('y').padding
  _makeScales : (guideSpec, domains, ranges) ->
    # this function contains information about default scales!
    specScale = (a) ->
      if guideSpec and guideSpec[a]? and guideSpec[a].scale?
        return guideSpec[a].scale
      return null
    scales = {}
    # x 
    scales.x = specScale('x') ? poly.scale.linear()
    scales.x.make(domains.x, ranges.x, @getSpec('x').padding)
    # y
    scales.y = specScale('y') ? poly.scale.linear()
    scales.y.make(domains.y, ranges.y, @getSpec('y').padding)
    # color
    if domains.color?
      if domains.color.type == 'cat'
        scales.color = specScale('color') ? poly.scale.color()
      else
        scales.color = specScale('color') ?
          poly.scale.gradient upper:'steelblue', lower:'red'
      scales.color.make(domains.color)
    # size
    if domains.size?
      scales.size = specScale('size') || poly.scale.area()
      scales.size.make(domains.size)
    # opacity
    if domains.opacity?
      scales.opacity= specScale('opacity') || poly.scale.opacity()
      scales.opacity.make(domains.opacity)
    # text
    scales.text = poly.scale.identity()
    scales.text.make()
    scales

  fromPixels: (start, end) ->
    {x,y} = @coord.getAes start, end, @reverse
    obj = {}
    for map in @layerMapping.x
      if map.type? and map.type == 'map'
        obj[map.value] = x
    for map in @layerMapping.y
      if map.type? and map.type == 'map'
        obj[map.value] = y
    obj

  getSpec : (a) -> if @guideSpec? and @guideSpec[a]? then @guideSpec[a] else {}

  makeTitles: (maintitle) ->
    @titles ?=
      x: poly.guide.title @coord.axisType('x')
      y: poly.guide.title @coord.axisType('y')
      main: poly.guide.title('main')
    @titles.main.make
      title: maintitle
      guideSpec: {}
      position: "top"
    @titles.x.make
      guideSpec: @getSpec 'x'
      title: poly.getLabel @layers, 'x'
    @titles.y.make
      guideSpec: @getSpec 'y'
      title: poly.getLabel @layers, 'y'
  titleOffset: (dim) ->
    offset = {}
    for key, title of @titles
      o = title.getDimension()
      for dir in ['left', 'right', 'top',' bottom']
        if o[dir]
          offset[dir] ?= 0
          offset[dir] += o[dir]
    offset
  renderTitles: (dims, renderer) ->
    renderer = renderer({}, false, false)
    o = @axesOffset(dims)
    @titles.x.render renderer, dims, o
    @titles.y.render renderer, dims, o
    @titles.main.render renderer, dims, o

  makeAxes: (groups) -> # groups = keys of panes
    {deleted, kept, added} = poly.compare(_.keys(@axes), groups)
    for key in deleted
      @deletedAxes.push @axes[key]
      delete @axes[key]
    for key in added
      @axes[key] =
        x: poly.guide.axis @coord.axisType('x')
        y: poly.guide.axis @coord.axisType('y')
    for key, axis of @axes
      axis.x.make
        domain: @domainx
        type: @scales.x.tickType()
        guideSpec: @getSpec 'x'
        key: poly.getLabel @layers, 'x'
      axis.y.make
        domain: @domainy
        type: @scales.y.tickType()
        guideSpec: @getSpec 'y'
        key: poly.getLabel @layers, 'y'
    @axes
  axesOffset: (dim) ->
    offset = {}
    done = {}
    for key, axis of @axes # loop over everything? pretty inefficient
      for k2, obj of axis
        if done[k2]? then continue
        d = obj.getDimension()
        if d.position == 'left'
          offset.left = d.width
        else if d.position == 'right'
          offset.right = d.width
        else if d.position == 'bottom'
          offset.bottom = d.height
        else if d.position == 'top'
          offset.top = d.height
        done[k2] = true
    offset
  renderAxes: (dims, renderer, facet) ->
    axis.remove(renderer) for axis in @deletedAxes
    @deletedAxes = []
    axisDim =
      top: 0
      left : 0
      right: dims.chartWidth
      bottom : dims.chartHeight
      width: dims.chartWidth
      height: dims.chartHeight
    drawx = drawy = null
    xoverride = renderLabel : false, renderTick : false
    yoverride = renderLabel : false, renderTick : false
    for key, axis of @axes
      offset = facet.getOffset(dims, key)
      if not drawx
        drawx = facet.edge(axis.x.position)
        drawy = facet.edge(axis.y.position)
        if axis.x.type is 'r'
          xoverride.renderLine = false
        if axis.y.type is 'r'
          yoverride.renderLine = false
      override = if drawx(key) then {} else xoverride
      axis.x.render axisDim, @coord, renderer(offset, false, false), override
      override = if drawy(key) then {} else yoverride
      axis.y.render axisDim, @coord, renderer(offset, false, false), override

  _mapLayers: (layers) ->
    obj = {}
    for aes of @domains
      obj[aes] =
        _.map layers, (layer) ->
          if layer.mapping[aes]?
            { type: 'map', value: layer.mapping[aes]}
          else if layer.consts[aes]?
            { type: 'const', value: layer.consts[aes]}
          else
            layer.defaults[aes]
    obj
  _mergeAes: (layers) ->
    merging = [] # array of {aes: __, mapped: ___}
    for aes of @domains
      if aes in poly.const.noLegend then continue
      mapped = _.map layers, (layer) -> layer.mapping[aes]
      if not _.all mapped, _.isUndefined
        merged = false
        for m in merging # slow but ok, <7 aes anyways...
          if _.isEqual(m.mapped, mapped)
            m.aes.push(aes)
            merged = true
            break
        if not merged
          merging.push {aes: [aes], mapped: mapped}
    _.pluck merging, 'aes'

  makeLegends: (mapping) -> # ok, this will be a complex f'n. deep breath:
    # figure out which groups of aesthetics need to be represented
    aesGroups = @_mergeAes @layers

    # now iterate through existing legends AND the aesGroups to see
    #   1) if any existing legends need to be deleted,
    #      in which case move that legend from @legends into @deletedLEgends
    #   2) if any new legends need to be created
    #      in which case KEEP it in aesGroups (otherwise remove)
    idx = 0
    while idx < @legends.length
      legend = @legends[idx]
      legenddeleted = true
      i = 0
      while i < aesGroups.length
        aes = aesGroups[i]
        if _.isEqual aes, legend.aes
          aesGroups.splice i, 1
          legenddeleted = false
          break
        i++
      if legenddeleted
        @deletedLegends.push legend
        @legends.splice(idx, 1)
      else
        idx++
    # create new legends
    for aes in aesGroups
      @legends.push poly.guide.legend aes
    # make each legend
    for legend in @legends
      aes = legend.aes[0]
      legend.make
        domain: @domains[aes]
        guideSpec: @getSpec aes
        type: @scales[aes].tickType()
        mapping: @layerMapping
        keys: poly.getLabel(@layers, aes)
    @legends
  legendOffset: (dim) ->
    maxheight =  dim.height - dim.guideTop - dim.paddingTop
    maxwidth = 0
    offset = { x: 10, y : 0 } # initial spacing
    for legend in @legends
      d = legend.getDimension()
      if d.height + offset.y > maxheight
        offset.x += maxwidth + 5
        offset.y = 0
        maxwidth = 0
      if d.width > maxwidth
        maxwidth = d.width
      offset.y += d.height
    right: offset.x + maxwidth # no height
  renderLegends: (dims, renderer) ->
    # NOTE: if this is changed, change dim.coffee dimension calculation
    legend.remove(renderer) for legend in @deletedLegends
    @deletedLegends = []
    offset = { x: 10, y : 0 } # initial spacing
    # axis offset
    offset.x += @axesOffset(dims).right ? 0
    offset.x += @titleOffset(dims).right ? 0

    maxwidth = 0
    maxheight = dims.height - dims.guideTop - dims.paddingTop
    for legend in @legends # assume position = right
      newdim = legend.getDimension()
      if newdim.height + offset.y > maxheight
        offset.x += maxwidth + 5
        offset.y = 0
        maxwidth = 0
      if newdim.width > maxwidth
        maxwidth = newdim.width
      legend.render dims, renderer, offset
      offset.y += newdim.height
