'*
'* DataLoader implementation for the home screen.
'*

Function createHomeScreenDataLoader(listener)
    loader = CreateObject("roAssociativeArray")
    initDataLoader(loader)

    ' TODO(schuyler): This feels like cheating...
    loader.ScreenID = -1
    loader.Listener = listener
    listener.Loader = loader

    loader.LoadMoreContent = homeLoadMoreContent
    loader.GetNames = homeGetNames
    loader.GetLoadStatus = homeGetLoadStatus
    loader.GetPendingRequestCount = loaderGetPendingRequestCount
    loader.RefreshData = homeRefreshData
    loader.OnUrlEvent = homeOnUrlEvent
    loader.OnServerDiscovered = homeOnServerDiscovered
    loader.OnMyPlexChange = homeOnMyPlexChange
    loader.RemoveInvalidServers = homeRemoveInvalidServers

    loader.CreateRow = homeCreateRow
    loader.CreateServerRequests = homeCreateServerRequests
    loader.CreateMyPlexRequests = homeCreateMyPlexRequests
    loader.CreatePlaylistRequests = homeCreatePlaylistRequests
    loader.CreateAllPlaylistRequests = homeCreateAllPlaylistRequests
    loader.RemoveFromRowIf = homeRemoveFromRowIf
    loader.AddOrStartRequest = homeAddOrStartRequest

    loader.contentArray = []
    loader.RowNames = []
    loader.RowIndexes = {}
    loader.FirstLoad = true
    loader.FirstServer = true

    rows = [
        { title: "Channels", key: "channels" },
        { title: "Library Sections", key: "sections" },
        { title: "On Deck", key: "on_deck" },
        { title: "Recently Added", key: "recently_added" },
        { title: "Queue", key: "queue" },
        { title: "Recommendations", key: "recommendations" },
        { title: "Shared Library Sections", key: "shared_sections" },
        { title: "Miscellaneous", key: "misc" }
    ]
    ReorderItemsByKeyPriority(rows, RegRead("home_row_order", "preferences", ""))

    for each row in rows
        loader.RowIndexes[row.key] = loader.CreateRow(row.title)
    next

    ' Kick off an asynchronous GDM discover.
    if RegRead("autodiscover", "preferences", "1") = "1" then
        loader.GDM = createGDMDiscovery(GetViewController().GlobalMessagePort, loader)
        if loader.GDM = invalid then
            Debug("Failed to create GDM discovery object")
        end if
    end if

    ' Kick off requests for servers we already know about.
    configuredServers = PlexMediaServers()
    Debug("Setting up home screen content, server count: " + tostr(configuredServers.Count()))
    for each server in configuredServers
        loader.CreateServerRequests(server, false, false)
    next

    ' Kick off myPlex requests if we're signed in.
    myPlex = GetMyPlexManager()
    myPlex.CheckAuthentication()
    if myPlex.IsSignedIn then
        loader.CreateMyPlexRequests(false)
    end if

    ' Create a static item for prefs and put it in the Misc row.
    prefs = CreateObject("roAssociativeArray")
    prefs.sourceUrl = ""
    prefs.ContentType = "prefs"
    prefs.Key = "globalprefs"
    prefs.Title = "Preferences"
    prefs.ShortDescriptionLine1 = "Preferences"
    prefs.SDPosterURL = "file://pkg:/images/gear.png"
    prefs.HDPosterURL = "file://pkg:/images/gear.png"
    loader.contentArray[loader.RowIndexes["misc"]].content.Push(prefs)

    ' Create an item for Now Playing in the Misc row that will be shown while
    ' the audio player is active.
    nowPlaying = CreateObject("roAssociativeArray")
    nowPlaying.sourceUrl = ""
    nowPlaying.ContentType = "audio"
    nowPlaying.Key = "nowplaying"
    nowPlaying.Title = "Now Playing"
    nowPlaying.ShortDescriptionLine1 = "Now Playing"
    nowPlaying.SDPosterURL = "file://pkg:/images/section-music.png"
    nowPlaying.HDPosterURL = "file://pkg:/images/section-music.png"
    nowPlaying.CurIndex = invalid
    loader.nowPlayingItem = nowPlaying

    loader.lastMachineID = RegRead("lastMachineID")
    loader.lastSectionKey = RegRead("lastSectionKey")

    loader.OnTimerExpired = homeOnTimerExpired

    ' As good a place as any, note that we've started
    analytics = GetViewController().Analytics
    analytics.OnStartup(myPlex.IsSignedIn)

    return loader
End Function

Function homeCreateRow(name) As Integer
    index = m.RowNames.Count()

    status = CreateObject("roAssociativeArray")
    status.content = []
    status.loadStatus = 0
    status.toLoad = CreateObject("roList")
    status.pendingRequests = 0
    status.refreshContent = invalid
    status.loadedServers = {}

    m.contentArray.Push(status)
    m.RowNames.Push(name)

    return index
End Function

Sub homeCreateServerRequests(server As Object, startRequests As Boolean, refreshRequest As Boolean)
    if not refreshRequest then
        PutPlexMediaServer(server)

        ' Request server details (ensure we have a machine ID, check transcoding
        ' support, etc.)
        httpRequest = server.CreateRequest("", "/")
        context = CreateObject("roAssociativeArray")
        context.requestType = "server"
        context.server = server
        GetViewController().StartRequest(httpRequest, m, context)
    end if

    ' Request sections
    sections = CreateObject("roAssociativeArray")
    sections.server = server
    sections.key = "/library/sections"
    m.AddOrStartRequest(sections, m.RowIndexes["sections"], startRequests)

    ' Request recently used channels
    view = RegRead("row_visibility_channels", "preferences", "")
    if view <> "hidden" then
        channels = CreateObject("roAssociativeArray")
        channels.server = server
        channels.key = "/channels/recentlyViewed"

        allChannels = CreateObject("roAssociativeArray")
        allChannels.Title = "More Channels"
        if AreMultipleValidatedServers() then
            allChannels.ShortDescriptionLine2 = "All channels on " + server.name
        else
            allChannels.ShortDescriptionLine2 = "All channels"
        end if
        allChannels.Description = allChannels.ShortDescriptionLine2
        allChannels.server = server
        allChannels.sourceUrl = ""
        allChannels.Key = "/channels/all"
        allChannels.SDPosterURL = "file://pkg:/images/more.png"
        allChannels.HDPosterURL = "file://pkg:/images/more.png"
        channels.item = allChannels
        m.AddOrStartRequest(channels, m.RowIndexes["channels"], startRequests)
    else
        m.Listener.OnDataLoaded(m.RowIndexes["channels"], [], 0, 0, true)
    end if

    ' Request global on deck
    view = RegRead("row_visibility_ondeck", "preferences", "")
    if view <> "hidden" then
        onDeck = CreateObject("roAssociativeArray")
        onDeck.server = server
        onDeck.key = "/library/onDeck"
        onDeck.requestType = "media"
        m.AddOrStartRequest(onDeck, m.RowIndexes["on_deck"], startRequests)
    else
        m.Listener.OnDataLoaded(m.RowIndexes["on_deck"], [], 0, 0, true)
    end if

    ' Request recently added
    view = RegRead("row_visibility_recentlyadded", "preferences", "")
    if view <> "hidden" then
        recents = CreateObject("roAssociativeArray")
        recents.server = server
        recents.key = "/library/recentlyAdded"
        recents.requestType = "media"
        m.AddOrStartRequest(recents, m.RowIndexes["recently_added"], startRequests)
    else
        m.Listener.OnDataLoaded(m.RowIndexes["recently_added"], [], 0, 0, true)
    end if
End Sub

Sub homeCreateMyPlexRequests(startRequests As Boolean)
    myPlex = GetMyPlexManager()

    if NOT myPlex.IsSignedIn then return

    ' Find any servers linked through myPlex
    httpRequest = myPlex.CreateRequest("", "/pms/servers")
    context = CreateObject("roAssociativeArray")
    context.requestType = "servers"
    GetViewController().StartRequest(httpRequest, m, context)

    ' Queue and recommendations requests
    m.CreateAllPlaylistRequests(startRequests)

    ' Shared sections request
    shared = CreateObject("roAssociativeArray")
    shared.server = myPlex
    shared.key = "/pms/system/library/sections"
    m.AddOrStartRequest(shared, m.RowIndexes["shared_sections"], startRequests)
End Sub

Sub homeCreateAllPlaylistRequests(startRequests As Boolean)
    if NOT GetMyPlexManager().IsSignedIn then return

    m.CreatePlaylistRequests("queue", "All Queued Items", "All queued items, including already watched items", m.RowIndexes["queue"], startRequests)
    m.CreatePlaylistRequests("recommendations", "All Recommended Items", "All recommended items, including already watched items", m.RowIndexes["recommendations"], startRequests)
End Sub

Sub homeCreatePlaylistRequests(name, title, description, row, startRequests)
    view = RegRead("playlist_view_" + name, "preferences", "unwatched")
    if view = "hidden" then
        m.Listener.OnDataLoaded(row, [], 0, 0, true)
        return
    end if

    ' Unwatched recommended items
    currentItems = CreateObject("roAssociativeArray")
    currentItems.server = GetMyPlexManager()
    currentItems.requestType = "playlist"
    currentItems.key = "/pms/playlists/" + name + "/" + view

    ' A dummy item to pull up the varieties (e.g. all and watched)
    allItems = CreateObject("roAssociativeArray")
    allItems.Title = title
    allItems.Description = description
    allItems.ShortDescriptionLine2 = allItems.Description
    allItems.server = currentItems.server
    allItems.sourceUrl = ""
    allItems.Key = "/pms/playlists/" + name
    allItems.SDPosterURL = "file://pkg:/images/more.png"
    allItems.HDPosterURL = "file://pkg:/images/more.png"
    allItems.ContentType = "playlists"
    currentItems.item = allItems
    currentItems.emptyItem = allItems

    m.AddOrStartRequest(currentItems, row, startRequests)
End Sub

Sub homeAddOrStartRequest(request As Object, row As Integer, startRequests As Boolean)
    status = m.contentArray[row]

    if startRequests then
        httpRequest = request.server.CreateRequest("", request.Key)
        request.row = row
        request.requestType = firstOf(request.requestType, "row")

        if GetViewController().StartRequest(httpRequest, m, request) then
            status.pendingRequests = status.pendingRequests + 1
        end if
    else
        status.toLoad.AddTail(request)
    end if
End Sub

Function IsMyPlexServer(item) As Boolean
    return (item.server <> invalid AND NOT item.server.IsConfigured)
End Function

Function AlwaysTrue(item) As Boolean
    return true
End Function

Function IsInvalidServer(item) As Boolean
    server = item.server
    if server <> invalid AND server.IsConfigured AND server.machineID <> invalid then
        return (GetPlexMediaServer(server.machineID) = invalid)
    else if item.key = "globalsearch"
        return (GetPrimaryServer() = invalid)
    else
        return false
    end if
End Function

Sub homeRemoveFromRowIf(row, predicate)
    newContent = []
    modified = false
    status = m.contentArray[row]

    for each item in status.content
        if predicate(item) then
            modified = true
        else
            newContent.Push(item)
        end if
    next

    if modified then
        Debug("Removed " + tostr(status.content.Count() - newContent.Count()) + " items from row" + tostr(row))
        status.content = newContent
        m.Listener.OnDataLoaded(row, newContent, 0, newContent.Count(), true)
    end if
End Sub

Function homeLoadMoreContent(focusedIndex, extraRows=0)
    myPlex = GetMyPlexManager()
    if m.FirstLoad then
        m.FirstLoad = false
        if NOT myPlex.IsSignedIn then
            m.Listener.OnDataLoaded(m.RowIndexes["queue"], [], 0, 0, true)
            m.Listener.OnDataLoaded(m.RowIndexes["recommendations"], [], 0, 0, true)
            m.Listener.OnDataLoaded(m.RowIndexes["shared_sections"], [], 0, 0, true)
        end if

        m.Listener.hasBeenFocused = false
        m.Listener.ignoreNextFocus = true

        if type(m.Listener.Screen) = "roGridScreen" then
            m.Listener.Screen.SetFocusedListItem(m.RowIndexes["sections"], 0)
        else
            m.Listener.Screen.SetFocusedListItem(m.RowIndexes["sections"])
        end if
    end if

    status = invalid
    extraRowsAlreadyLoaded = true
    for i = 0 to extraRows
        index = focusedIndex + i
        if index >= m.contentArray.Count() then
            exit for
        else if m.contentArray[index].loadStatus = 0 OR m.contentArray[index].toLoad.Count() > 0 then
            if status = invalid then
                status = m.contentArray[index]
                loadingRow = index
            else
                extraRowsAlreadyLoaded = false
                exit for
            end if
        end if
    end for

    if status = invalid then return true

    ' If we have something to load, kick off all the requests asynchronously
    ' now. Otherwise return according to whether or not additional rows have
    ' requests that need to be kicked off. As a special case, if there's
    ' nothing to load and no pending requests, we must be in a row with static
    ' content, tell the screen it's been loaded.

    if status.toLoad.Count() > 0 then
        status.loadStatus = 1

        origCount = status.pendingRequests
        for each toLoad in status.toLoad
            m.AddOrStartRequest(toLoad, loadingRow, true)
        next
        numRequests = status.pendingRequests - origCount

        status.toLoad.Clear()

        Debug("Successfully kicked off " + tostr(numRequests) + " requests for row " + tostr(loadingRow) + ", pending requests now: " + tostr(status.pendingRequests))
    else if status.pendingRequests > 0 then
        status.loadStatus = 1
        Debug("No additional requests to kick off for row " + tostr(loadingRow) + ", pending request count: " + tostr(status.pendingRequests))
    else
        ' Special case, if we try loading the Misc row and have no servers,
        ' this is probably a first run scenario, try to be helpful.
        if loadingRow = m.RowIndexes["misc"] AND RegRead("serverList", "servers") = invalid AND NOT myPlex.IsSignedIn then
            if RegRead("autodiscover", "preferences", "1") = "1" then
                if m.GdmTimer = invalid then
                    ' Give GDM discovery a chance...
                    m.LoadingFacade = CreateObject("roOneLineDialog")
                    m.LoadingFacade.SetTitle("Looking for Plex Media Servers...")
                    m.LoadingFacade.ShowBusyAnimation()
                    m.LoadingFacade.Show()

                    m.GdmTimer = createTimer()
                    m.GdmTimer.Name = "GDM"
                    m.GdmTimer.SetDuration(5000)
                    GetViewController().AddTimer(m.GdmTimer, m)
                end if
            else
                ' Slightly strange, GDM disabled but no servers configured
                Debug("No servers, no GDM, and no myPlex...")
                ShowHelpScreen()
                status.loadStatus = 2
                m.Listener.OnDataLoaded(loadingRow, status.content, 0, status.content.Count(), true)
            end if
        else
            status.loadStatus = 2
            m.Listener.OnDataLoaded(loadingRow, status.content, 0, status.content.Count(), true)
        end if
    end if

    return extraRowsAlreadyLoaded
End Function

Sub homeOnUrlEvent(msg, requestContext)
    status = invalid
    if requestContext.row <> invalid then
        status = m.contentArray[requestContext.row]
        status.pendingRequests = status.pendingRequests - 1
    end if

    url = tostr(requestContext.Request.GetUrl())
    server = requestContext.server

    if msg.GetResponseCode() <> 200 then
        Debug("Got a " + tostr(msg.GetResponseCode()) + " response from " + url + " - " + tostr(msg.GetFailureReason()))

        if status <> invalid AND status.loadStatus < 2 AND status.pendingRequests = 0 then
            status.loadStatus = 2
            if status.refreshContent <> invalid then
                status.content = status.refreshContent
                status.refreshContent = invalid
            end if
            m.Listener.OnDataLoaded(requestContext.row, status.content, 0, status.content.Count(), true)
        end if

        return
    else
        Debug("Got a 200 response from " + url + " (type " + tostr(requestContext.requestType) + ", row " + tostr(requestContext.row) + ")")
    end if

    xml = CreateObject("roXMLElement")
    xml.Parse(msg.GetString())

    if requestContext.requestType = "row" then
        countLoaded = 0
        content = firstOf(status.refreshContent, status.content)
        startItem = content.Count()

        server.IsAvailable = true
        machineId = tostr(server.MachineID)

        if status.loadedServers.DoesExist(machineID) then
            Debug("Ignoring content for server that was already loaded: " + machineID)
            items = []
            requestContext.item = invalid
            requestContext.emptyItem = invalid
        else
            status.loadedServers[machineID] = "1"
            response = CreateObject("roAssociativeArray")
            response.xml = xml
            response.server = server
            response.sourceUrl = url
            container = createPlexContainerForXml(response)
            items = container.GetMetadata()

            if AreMultipleValidatedServers() then
                serverStr = " on " + server.name
            else
                serverStr = ""
            end if
        end if

        for each item in items
            add = true

            ' A little weird, but sections will only have owned="1" on the
            ' myPlex request, so we ignore them here since we should have
            ' also requested them from the server directly.
            if item.Owned = "1" then
                add = false
            else if item.MachineID <> invalid then
                existingServer = GetPlexMediaServer(item.MachineID)
                if existingServer <> invalid then
                    Debug("Found a server for the section: " + tostr(item.Title) + " on " + tostr(existingServer.name))
                    item.server = existingServer
                    serverStr = " on " + existingServer.name
                else
                    Debug("Found a shared section for an unknown server: " + tostr(item.MachineID))
                    add = false
                end if
            end if

            if NOT add then
            else if item.Type = "channel" then
                channelType = Mid(item.key, 2, 5)
                if channelType = "music" then
                    item.ShortDescriptionLine2 = "Music channel" + serverStr
                else if channelType = "photo" then
                    item.ShortDescriptionLine2 = "Photo channel" + serverStr
                else if channelType = "video" then
                    item.ShortDescriptionLine2 = "Video channel" + serverStr
                else
                    Debug("Skipping unsupported channel type: " + tostr(channelType))
                    add = false
                end if
            else if item.Type = "movie" then
                item.ShortDescriptionLine2 = "Movie section" + serverStr
            else if item.Type = "show" then
                item.ShortDescriptionLine2 = "TV section" + serverStr
            else if item.Type = "artist" then
                item.ShortDescriptionLine2 = "Music section" + serverStr
            else if item.Type = "photo" then
                item.ShortDescriptionLine2 = "Photo section" + serverStr
            else
                Debug("Skipping unsupported section type: " + tostr(item.Type))
                add = false
            end if

            if add then
                item.Description = item.ShortDescriptionLine2

                ' Normally thumbnail requests will have an X-Plex-Token header
                ' added as necessary by the screen, but we can't do that on the
                ' home screen because we're showing content from multiple
                ' servers.
                if item.SDPosterURL <> invalid AND Left(item.SDPosterURL, 4) = "http" AND item.server <> invalid AND item.server.AccessToken <> invalid then
                    item.SDPosterURL = item.SDPosterURL + "&X-Plex-Token=" + item.server.AccessToken
                    item.HDPosterURL = item.HDPosterURL + "&X-Plex-Token=" + item.server.AccessToken
                end if

                content.Push(item)
                countLoaded = countLoaded + 1
            end if
        next

        if requestContext.item <> invalid AND countLoaded > 0 then
            countLoaded = countLoaded + 1
            content.Push(requestContext.item)
        else if requestContext.emptyItem <> invalid AND countLoaded = 0 then
            countLoaded = countLoaded + 1
            content.Push(requestContext.emptyItem)
        end if

        if status.toLoad.Count() = 0 AND status.pendingRequests = 0 then
            status.loadStatus = 2
        end if

        if status.refreshContent <> invalid then
            if status.toLoad.Count() = 0 AND status.pendingRequests = 0 then
                status.content = status.refreshContent
                status.refreshContent = invalid
                m.Listener.OnDataLoaded(requestContext.row, status.content, 0, status.content.Count(), true)
            end if
        else
            m.Listener.OnDataLoaded(requestContext.row, status.content, startItem, countLoaded, true)
        end if

        if m.Listener.hasBeenFocused = false AND requestContext.row = m.RowIndexes["sections"] AND type(m.Listener.Screen) = "roGridScreen" AND server.machineID = m.lastMachineID then
            Debug("Trying to focus last used section")
            for i = 0 to status.content.Count() - 1
                if status.content[i].key = m.lastSectionKey then
                    m.Listener.Screen.SetFocusedListItem(requestContext.row, i)
                    exit for
                end if
            next
        end if
    else if requestContext.requestType = "media" then
        countLoaded = 0
        content = firstOf(status.refreshContent, status.content)
        startItem = content.Count()

        server.IsAvailable = true
        machineId = tostr(server.MachineID)

        if status.loadedServers.DoesExist(machineID) then
            Debug("Ignoring content for server that was already loaded: " + machineID)
            items = []
            requestContext.item = invalid
            requestContext.emptyItem = invalid
        else
            status.loadedServers[machineID] = "1"
            response = CreateObject("roAssociativeArray")
            response.xml = xml
            response.server = server
            response.sourceUrl = url
            container = createPlexContainerForXml(response)
            items = container.GetMetadata()
        end if

        for each item in items
            ' Normally thumbnail requests will have an X-Plex-Token header
            ' added as necessary by the screen, but we can't do that on the
            ' home screen because we're showing content from multiple
            ' servers.
            if item.SDPosterURL <> invalid AND Left(item.SDPosterURL, 4) = "http" AND item.server <> invalid AND item.server.AccessToken <> invalid then
                item.SDPosterURL = item.SDPosterURL + "&X-Plex-Token=" + item.server.AccessToken
                item.HDPosterURL = item.HDPosterURL + "&X-Plex-Token=" + item.server.AccessToken
            end if

            content.Push(item)
            countLoaded = countLoaded + 1
        next

        if status.toLoad.Count() = 0 AND status.pendingRequests = 0 then
            status.loadStatus = 2
        end if

        if status.refreshContent <> invalid then
            if status.toLoad.Count() = 0 AND status.pendingRequests = 0 then
                status.content = status.refreshContent
                status.refreshContent = invalid
                m.Listener.OnDataLoaded(requestContext.row, status.content, 0, status.content.Count(), true)
            end if
        else
            m.Listener.OnDataLoaded(requestContext.row, status.content, startItem, countLoaded, true)
        end if
    else if requestContext.requestType = "playlist" then
        response = CreateObject("roAssociativeArray")
        response.xml = xml
        response.server = server
        response.sourceUrl = url
        container = createPlexContainerForXml(response)

        status.content = container.GetMetadata()

        if requestContext.item <> invalid AND status.content.Count() > 0 then
            status.content.Push(requestContext.item)
        else if requestContext.emptyItem <> invalid AND status.content.Count() = 0 then
            status.content.Push(requestContext.emptyItem)
        end if

        status.loadStatus = 2

        m.Listener.OnDataLoaded(requestContext.row, status.content, 0, status.content.Count(), true)
    else if requestContext.requestType = "server" then
        ' If the machine ID doesn't match what we expected then disregard,
        ' it was probably a myPlex local address that hasn't been updated.
        ' If we already have a server then disregard, we might have made
        ' multiple requests for local addresses and the first one back wins.

        existing = GetPlexMediaServer(xml@machineIdentifier)
        if server.machineID <> invalid AND server.machineID <> xml@machineIdentifier then
            Debug("Ignoring server response from unexpected machine ID")
        else
            if existing <> invalid AND existing.online then
                if server.local = true then
                    Debug("Updating " + tostr(existing.name) + " to use local address: " + server.serverUrl)
                    existing.serverUrl = server.serverUrl
                end if
                duplicate = true
            else
                duplicate = false
            end if

            server.name = firstOf(xml@friendlyName, server.name)
            server.machineID = xml@machineIdentifier
            server.online = true
            server.SupportsAudioTranscoding = (xml@transcoderAudio = "1")
            server.SupportsVideoTranscoding = (xml@transcoderVideoQualities <> invalid)
            server.SupportsPhotoTranscoding = server.machineID <> "myPlex"
            server.SupportsUniversalTranscoding = ServerVersionCompare(xml@version, [0, 9, 7, 15])
            server.AllowsMediaDeletion = server.owned AND (xml@allowMediaDeletion = "1")
            server.IsAvailable = true
            server.IsSecondary = (xml@serverClass = "secondary")
            server.SupportsMultiuser = (xml@multiuser = "1")
            if server.AccessToken = invalid AND ServerVersionCompare(xml@version, [0, 9, 7, 15]) then
                server.AccessToken = GetMyPlexManager().AuthToken
            end if

            PutPlexMediaServer(server)

            Debug("Fetched additional server information (" + tostr(server.name) + ", " + tostr(server.machineID) + ")")
            Debug("URL: " + tostr(server.serverUrl))
            Debug("Server supports audio transcoding: " + tostr(server.SupportsAudioTranscoding))
            Debug("Server allows media deletion: " + tostr(server.AllowsMediaDeletion))
            Debug("Server supports universal transcoding: " + tostr(server.SupportsUniversalTranscoding))

            if server.owned AND NOT duplicate then
                status = m.contentArray[m.RowIndexes["misc"]]
                machineId = tostr(server.machineID)
                if NOT server.IsSecondary AND NOT status.loadedServers.DoesExist(machineID) then
                    status.loadedServers[machineID] = "1"
                    channelDir = CreateObject("roAssociativeArray")
                    channelDir.server = server
                    channelDir.sourceUrl = ""
                    channelDir.key = "/system/appstore"
                    channelDir.Title = "Channel Directory"
                    if AreMultipleValidatedServers() then
                        channelDir.ShortDescriptionLine2 = "Browse channels to install on " + server.name
                    else
                        channelDir.ShortDescriptionLine2 = "Browse channels to install"
                    end if
                    channelDir.Description = channelDir.ShortDescriptionLine2
                    channelDir.SDPosterURL = "file://pkg:/images/more.png"
                    channelDir.HDPosterURL = "file://pkg:/images/more.png"
                    status.content.Push(channelDir)
                end if

                if m.FirstServer then
                    m.FirstServer = false

                    if m.LoadingFacade <> invalid then
                        m.LoadingFacade.Close()
                        m.LoadingFacade = invalid
                        m.GdmTimer.Active = false
                        m.GdmTimer = invalid
                    end if

                    ' Add universal search now that we have a server
                    univSearch = CreateObject("roAssociativeArray")
                    univSearch.sourceUrl = ""
                    univSearch.ContentType = "search"
                    univSearch.Key = "globalsearch"
                    univSearch.Title = "Search"
                    univSearch.Description = "Search for items across all your sections and channels"
                    univSearch.ShortDescriptionLine2 = univSearch.Description
                    univSearch.SDPosterURL = "file://pkg:/images/search.png"
                    univSearch.HDPosterURL = "file://pkg:/images/search.png"
                    status.content.Unshift(univSearch)
                    m.Listener.OnDataLoaded(m.RowIndexes["misc"], status.content, 0, status.content.Count(), true)
                else
                    m.Listener.OnDataLoaded(m.RowIndexes["misc"], status.content, status.content.Count() - 1, 1, true)
                end if
            end if
        end if
    else if requestContext.requestType = "servers" then
        for each serverElem in xml.Server
            ' If we already have a server for this machine ID then disregard
            existing = GetPlexMediaServer(serverElem@machineIdentifier)
            if serverElem@port = "443" then
                addr = "https://" + serverElem@host
            else
                addr = "http://" + serverElem@host + ":" + serverElem@port
            end if
            if existing <> invalid AND (existing.IsAvailable OR existing.ServerUrl = addr) then
                Debug("Ignoring duplicate shared server: " + tostr(serverElem@machineIdentifier))
            else
                if existing = invalid then
                    newServer = newPlexMediaServer(addr, serverElem@name, serverElem@machineIdentifier)
                else
                    newServer = existing
                    newServer.ServerUrl = addr
                end if

                newServer.AccessToken = firstOf(serverElem@accessToken, GetMyPlexManager().AuthToken)

                if serverElem@owned = "1" then
                    ' If we got local addresses, kick off simultaneous requests for all
                    ' of them. The first one back will win, so we should always use the
                    ' most efficient connection.
                    localAddresses = strTokenize(serverElem@localAddresses, ",")
                    for each localAddress in localAddresses
                        localServer = newPlexMediaServer("http://" + localAddress + ":32400", serverElem@name, serverElem@machineIdentifier)
                        localServer.owned = true
                        localServer.local = true
                        localServer.AccessToken = firstOf(serverElem@accessToken, GetMyPlexManager().AuthToken)
                        m.CreateServerRequests(localServer, true, false)
                    next

                    newServer.name = firstOf(serverElem@name, newServer.name)
                    newServer.owned = true
                    newServer.local = false

                    ' An owned server that we didn't have configured, request
                    ' its sections and channels now.
                    m.CreateServerRequests(newServer, true, false)
                else
                    newServer.name = firstOf(serverElem@name, newServer.name) + " (shared by " + serverElem@sourceTitle + ")"
                    newServer.owned = false

                    ' Request server details (ensure we have a machine ID, check
                    ' transcoding support, etc.)
                    newRequest = newServer.CreateRequest("", "/")
                    newContext = CreateObject("roAssociativeArray")
                    newContext.requestType = "server"
                    newContext.server = newServer
                    GetViewController().StartRequest(newRequest, m, newContext)
                end if
                PutPlexMediaServer(newServer)

                Debug("Added myPlex server: " + tostr(newServer.name))
            end if
        next
    end if
End Sub

Sub homeOnServerDiscovered(serverInfo)
    Debug("GDM discovery found server at " + tostr(serverInfo.Url))

    existing = GetPlexMediaServer(serverInfo.MachineID)
    if existing <> invalid then
        if existing.ServerUrl = serverInfo.Url then
            Debug("GDM discovery ignoring already configured server")
        else
            Debug("Found new address for " + serverInfo.Name + ": " + existing.ServerUrl + " -> " + serverInfo.Url)
            existing.Name = serverInfo.Name
            existing.ServerUrl = serverInfo.Url
            existing.owned = true
            existing.IsConfigured = true
            existing.local = true
            m.CreateServerRequests(existing, true, false)
            UpdateServerAddress(existing)
        end if
    else
        AddServer(serverInfo.Name, serverInfo.Url, serverInfo.MachineID)
        server = newPlexMediaServer(serverInfo.Url, serverInfo.Name, serverInfo.MachineID)
        server.owned = true
        server.IsConfigured = true
        server.local = true
        PutPlexMediaServer(server)
        m.CreateServerRequests(server, true, false)
    end if
End Sub

Function homeGetNames()
    return m.RowNames
End Function

Function homeGetLoadStatus(row)
    return m.contentArray[row].loadStatus
End Function

Sub homeRefreshData()
    ' Update the Now Playing item according to whether or not something is playing
    audioPlayer = GetViewController().AudioPlayer
    miscContent = m.contentArray[m.RowIndexes["misc"]].content
    if m.nowPlayingItem.CurIndex = invalid AND audioPlayer.ContextScreenID <> invalid then
        m.nowPlayingItem.CurIndex = miscContent.Count()
        miscContent.Push(m.nowPlayingItem)
    else if m.nowPlayingItem.CurIndex <> invalid AND audioPlayer.ContextScreenID = invalid then
        miscContent.Delete(m.nowPlayingItem.CurIndex)
        m.nowPlayingItem.CurIndex = invalid
    end if

    ' The home screen is never empty, make sure we don't close ourself.
    m.Listener.hasData = true

    ' Refresh the queue
    m.CreateAllPlaylistRequests(true)

    ' Refresh the sections and channels for all of our owned servers
    m.contentArray[m.RowIndexes["sections"]].refreshContent = []
    m.contentArray[m.RowIndexes["sections"]].loadedServers.Clear()
    m.contentArray[m.RowIndexes["channels"]].refreshContent = []
    m.contentArray[m.RowIndexes["channels"]].loadedServers.Clear()
    m.contentArray[m.RowIndexes["on_deck"]].refreshContent = []
    m.contentArray[m.RowIndexes["on_deck"]].loadedServers.Clear()
    m.contentArray[m.RowIndexes["recently_added"]].refreshContent = []
    m.contentArray[m.RowIndexes["recently_added"]].loadedServers.Clear()

    for each server in GetOwnedPlexMediaServers()
        m.CreateServerRequests(server, true, true)
    next

    ' Clear any screensaver images, use the default.
    SaveImagesForScreenSaver(invalid, {})
End Sub

Sub homeOnMyPlexChange()
    Debug("myPlex status changed")

    if GetMyPlexManager().IsSignedIn then
        m.CreateMyPlexRequests(true)
    else
        m.RemoveFromRowIf(m.RowIndexes["sections"], IsMyPlexServer)
        m.RemoveFromRowIf(m.RowIndexes["channels"], IsMyPlexServer)
        m.RemoveFromRowIf(m.RowIndexes["on_deck"], IsMyPlexServer)
        m.RemoveFromRowIf(m.RowIndexes["recently_added"], IsMyPlexServer)
        m.RemoveFromRowIf(m.RowIndexes["misc"], IsMyPlexServer)
        m.RemoveFromRowIf(m.RowIndexes["queue"], AlwaysTrue)
        m.RemoveFromRowIf(m.RowIndexes["recommendations"], AlwaysTrue)
        m.RemoveFromRowIf(m.RowIndexes["shared_sections"], AlwaysTrue)
    end if
End Sub

Sub homeRemoveInvalidServers()
    m.RemoveFromRowIf(m.RowIndexes["sections"], IsInvalidServer)
    m.RemoveFromRowIf(m.RowIndexes["channels"], IsInvalidServer)
    m.RemoveFromRowIf(m.RowIndexes["on_deck"], IsInvalidServer)
    m.RemoveFromRowIf(m.RowIndexes["recently_added"], IsInvalidServer)
    m.RemoveFromRowIf(m.RowIndexes["misc"], IsInvalidServer)
End Sub

Sub homeOnTimerExpired(timer)
    if timer.Name = "GDM" then
        Debug("Done waiting for GDM")

        if m.LoadingFacade <> invalid then
            m.LoadingFacade.Close()
            m.LoadingFacade = invalid
        end if

        m.GdmTimer = invalid

        if RegRead("serverList", "servers") = invalid AND NOT GetMyPlexManager().IsSignedIn then
            Debug("No servers and no myPlex, appears to be a first run")
            ShowHelpScreen()
            status = m.contentArray[m.RowIndexes["misc"]]
            status.loadStatus = 2
            m.Listener.OnDataLoaded(m.RowIndexes["misc"], status.content, 0, status.content.Count(), true)
        end if
    end if
End Sub
