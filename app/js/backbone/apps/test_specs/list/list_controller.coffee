@App.module "TestSpecsApp.List", (List, App, Backbone, Marionette, $, _) ->

  class List.Controller extends App.Controllers.Application

    initialize: (options) ->
      { runner, iframe, spec } = options

      testViewQueue = testQueue = null

      config = App.request("app:config:entity")

      numTestsKeptInMemory = config.get("numTestsKeptInMemory")

      ## hold onto every single runnable type (suite or test)
      container  = App.request "runnable:container:entity"

      ## generate the root runnable which holds everything
      root = App.request "new:root:runnable:entity"

      ## grab the commands collection from the runner
      { commands, routes, agents} = runner

      ## when commands are added to this collection
      ## we need to find the runnable model by its id
      ## and then add this command model to the runnable model
      @listenTo commands, "add", (command, commands, options) ->
        model = container.get command.get("testId")
        return if not model

        command = model.addCommand(command, options)

      @listenTo routes, "add", (route, routes, options) ->
        model = container.get route.get("testId")
        model.addRoute(route, options) if model

      @listenTo agents, "add", (agent, agents, options) ->
        model = container.get agent.get("testId")
        model.addAgent(agent, options) if model

      ## always make the first two arguments the root model + container collection
      @addRunnable = _.partial(@addRunnable, root, container)

      ## always make the first two arguments the runner + container collection
      @createRunnableListeners = _.partial(@createRunnableListeners, runner, container)

      ## always make the first argument the runner
      @insertChildViews = _.partial(@insertChildViews, runner, iframe)

      @listenTo runner, "paused", ->
        ## open the runnable if we find one
        ## when the pause is clicked
        runnable = container.find (r) ->
          r.get("state") is "active"

        runnable?.open()

      @listenTo runner, "before:run", ->
        testViewQueue = []
        testQueue     = []

        ## move all the models over to previous run
        ## and reset all existing one
        container.reset()

      @listenTo runner, "before:add", (total) ->
        ## unbind all listeners so we dont display anything
        ## if we're in headless mode and have more than 200 tests
        ## in CI and when running headlessly we cannot
        ## startup the specsRegion because this will cause
        ## tests to timeout when there are thousands
        ## this doesnt indicate a memory leak, i believe
        ## its simply creates too many object references
        ## and without any DOM optimizations it simply
        ## creates hundreds of thousands of new nodes
        if config.get("isHeadless") and total > 200
          events = "after:add suite:add suite:end test:add test:start test:end".split(" ")
          events.forEach (event) =>
            @stopListening(runner, event)

      @listenTo runner, "after:add", ->
        ## removes any old models no longer in our run
        container.removeOldModels()

        ## if container is empty then we want
        ## to have our runnablesView render its
        ## empty view
        if container.isEmpty()
          runnablesView.renderEmpty = true
          runnablesView.render()
        else
          ## reset the renderEmpty variable back to false
          ## else sometime later when this view is re-rendered
          ## if it had its renderEmpty variable set to true
          ## we would see an empty view alongside a non-empty
          ## view (which was a bug)
          ## https://github.com/cypress-io/cypress/issues/13
          runnablesView.renderEmpty = false

        ## if theres only 1 single test we always
        ## want to choose it so its open by default
        if model = container.hasOnlyOneTest()
          model.open()

        @startInsertingTestViews(testViewQueue)

      @listenTo runner, "suite:add", (suite) ->
        @addRunnable(suite, "suite", testViewQueue)
      # @listenTo runner, "suite:start", (suite) ->
        # @addRunnable(suite, "suite")

      @listenTo runner, "suite:end", (suite) ->
        return if suite.root

        ## when our suite stop update its state
        ## based on all the tests that ran
        container.get(suite.id).updateState()

      # add the test to the suite unless it already exists
      @listenTo runner, "test:add", (test) ->
        ## add the test to the container collection of runnables
        @addRunnable(test, "test", testViewQueue)

      @listenTo runner, "test:start", (test) ->
        runnable = container.get(test.id)
        runnable.activate() if runnable

      @listenTo runner, "test:end", (test) ->
        ## find the client runnable model by the test's ide
        runnable = container.get(test.id)

        @addRunnableToQueue(testQueue, runnable, numTestsKeptInMemory)

        ## set the results of the test on the test client model
        ## passed | failed | pending
        runnable.setResults(test)

        ## this logs the results of the test
        ## and causes our runner to fire 'test:results:ready'
        runner.logResults runnable

      @listenTo runner, "reset:test:run", ->
        ## when our runner says to reset the test run
        ## we do this so our tests go into the 'reset' state prior to the iframe
        ## loading -- so it visually looks like things are moving along faster
        ## and it gives a more accurate portrayal of whats about to happen
        ## your tests are going to re-run!
        root.reset()

      runnablesView = @getRunnablesView root, spec

      @show runnablesView

    addRunnable: (root, container, runnable, type, testViewQueue) ->
      ## we need to bail here because this is most likely due
      ## to the user changing their tests and the old test
      ## are still running...
      return if runnable.root

      ## add it to our flat container
      ## and figure out where this model should be added
      ## does it go into an existing nested collection?
      ## or does it belong on the root?
      runnable = container.add runnable, type, root

      @createRunnableListeners(runnable)

      testViewQueue.push(runnable)

    addRunnableToQueue: (queue, test, numTestsKeptInMemory) ->
      queue.push(test)

      @cleanupQueue(queue, numTestsKeptInMemory)

    cleanupQueue: (queue, numTestsKeptInMemory) ->
      if queue.length > numTestsKeptInMemory
        runnable = queue.shift()
        runnable.reduceCommandMemory()
        @cleanupQueue(queue, numTestsKeptInMemory)

    startInsertingTestViews: (testViewQueue) ->
      return if not runnable = testViewQueue.shift()

      @insertChildViews(runnable)

      requestAnimationFrame =>
        @startInsertingTestViews(testViewQueue)

    insertChildViews: (runner, iframe, model) ->
      ## we could alternatively loop through all of the children
      ## from the root as opposed to going through the model
      ## to receive its layout but that would be much slower
      ## because we have unlimited nesting, unfortunately
      ## this is the easiest way to receive our layout view
      model.trigger "get:layout:view", (layout) =>

        ## insert the content view into the layout
        contentView = @getRunnableContentView(model)
        @show contentView, region: layout.contentRegion

        if model.is("test")
          ## if we've refreshed a test without hard refreshing
          ## the browser and we already have view instances then
          ## dont reinsert them. we just reset their collections
          ## which achieves the same results
          return if layout.commandsRegion.hasView()

          App.execute "list:test:agents", model, layout.agentsRegion

          App.execute "list:test:routes", model, layout.routesRegion

          ## and pass up the commands collection (via hooks) and the commands region
          App.execute "list:test:commands", model, iframe, layout.commandsRegion
        else
          region = layout.runnablesRegion

          ## dont replace the current view if theres one in the region
          ## else this would cause all of our existing tests to be removed
          return if region.hasView()

          ## repeat the nesting by inserting the collection view again
          runnablesView = @getRunnablesView model
          @show runnablesView, region: region

    createRunnableListeners: (runner, container, model) ->
      ## unbind everything else we will get duplicated events
      @stopListening model

      ## because we have infinite view nesting we can't really utilize
      ## the view event bus in a reliable way.  thus we have to go through
      ## our models.

      ## we also can't use the normal backbone-chooser because
      ## we have unlimited nested / fragmented collections
      ## so we have to handle this logic ourselves
      @listenTo model, "model:refresh:clicked", ->
        ## always unchoose all other models
        container.each (runnable) ->
          runnable.collapse()
          runnable.unchoose()

        ## choose this model
        model.reset({silent: false})
        model.choose()

        ## pass this id along to runner
        runner.setChosen model

    getRunnableContentView: (runnable) ->
      new List.RunnableContent
        model: runnable

    getRunnablesView: (runnable, spec) ->
      new List.Runnables
        model: runnable
        spec: spec