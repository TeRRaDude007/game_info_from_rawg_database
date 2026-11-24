# -----------------------------------------------------------------------------
# TeRRaDuDe RAWG Game Database for PC / PlayStation / Xbox / Nintendo Switch / iOS / Android - Eggdrop Tcl Script
#
# Version: 1.0.14
#
# Changelog...: 
#          Suppress no-match channel notices for automatic NEWDIR lookups; keep manual feedback.
#          Require the main title keyword to match before accepting a RAWG result.
#          Prevent unrelated partial matches (for example, Ace Combat for TIEBREAK).
#          Strip trailing release years (19xx/20xx) before RAWG game searches.
#          Improve RAWG result selection using normalized title-token scoring.
#          Add configurable public game-info trigger.
#          Centralize release/title normalization for manual and automatic lookups.
#          Strip common PC/PS5/NSW release metadata while preserving meaningful title text.
#          Keep PZS-NG registration retries and relative glFTPd path matching from v1.0.8.
#
# Requires: Eggdrop 1.9.x, Tcl 8.6+, Tcllib http, json, tls, API key (https://rawg.io/@traver/apikey)
#
# Commands:
#   <gameinfo_trigger> <game name>  Search RAWG and show game information.
#   !gameid <RAWG ID>         Look up a game by its RAWG database ID.
#   !rawgpreview <release>    Preview an automatic release announcement in-channel.
#
# PZS-NG:
#   Registers the global ::rawg event dispatcher as "rawg" for NEWDIR.
#   Only direct releases below the configured cfg(announce_dirs) roots
#   are handled. Other sections/paths are ignored.
#
# -----------------------------------------------------------------------------
# 0 = OFF / 1 = ON
# --------------------------- CONFIG SETUP ------------------------------------
namespace eval ::rawg {
    variable version "1.0.14"
    variable scriptName "rawg"
    variable cache
    variable cfg
    variable registration_timer ""
    variable registration_attempts 0
    if {![info exists gameinfo_bound_trigger]} {
        variable gameinfo_bound_trigger ""
    }
    array set cfg {
        enabled                 1
        api_key                 "myAPIKeyshouldbehere"
        api_url                 "https://api.rawg.io/api"
        user_agent              "Eggdrop-RAWG/1.0.14"
        timeout                 12000
        max_retries             2
        retry_delay             2
        cache_enabled           1
        cache_ttl               3600

        sandbox_mode            0
        debug                   0

        auto_release_enabled    0
        auto_release_channels   {#channel}
        announce_dirs           {/glftpd/site/GAMES /glftpd/site/NSW /glftpd/site/XBOX /glftpd/site/PS4 /glftpd/site/PS5}
        auto_release_delay      1

        announce_header         1
        show_name               1
        show_rawg_id            1
        show_rating             1
        show_release            1
        show_genres             1
        show_platforms          1
        show_metacritic         1
        show_website            1

        announce_header_2       1
        show_developers         1
        show_publishers         1
        show_esrb               1
        show_rawg_url           1

        announce_header_3       1
        show_description        1
        description_max_length  250

        max_line_length         450
        command_flags           "-"
        preview_enabled         1

        # Public command used to search for a game (without the leading !).
        # Examples: gameinfo, game, info
        gameinfo_trigger        "game"

    }

    array set cache {}
}

# --------------------------- END OF SETUP ------------------------------------
#
# -----------------------------------------------------------------------------
# SCRiPT START HERE DONT EDiT BELOW / LOGGING AND IRC OUTPUT
# -----------------------------------------------------------------------------

proc ::rawg::log {message} {
    variable cfg
    if {$cfg(debug)} {
        putlog "RAWG: $message"
    }
}

proc ::rawg::label {name} {
    return "\00314${name}:\003"
}

proc ::rawg::value {data} {
    return "\00303${data}\003"
}

proc ::rawg::field {name data} {
    if {$data eq "" || $data eq "-"} {
        return ""
    }
    return "[label $name] [value $data]"
}

proc ::rawg::clean_text {value} {
    set value [string map [list "\r" " " "\n" " " "\t" " "] $value]
    regsub -all {\s+} $value { } value
    return [string trim $value]
}

proc ::rawg::get {object key {default ""}} {
    if {[catch {dict exists $object $key} exists] || !$exists} {
        return $default
    }
    if {[catch {dict get $object $key} result]} {
        return $default
    }
    return $result
}

proc ::rawg::decode {data} {
    if {[catch {::json::json2dict $data} result]} {
        log "JSON DECODE ERROR: $result"
        return ""
    }
    return $result
}

proc ::rawg::names_from_objects {items object_key} {
    set names {}
    foreach item $items {
        if {$object_key eq ""} {
            set name [get $item name]
        } else {
            set object [get $item $object_key]
            set name [get $object name]
        }
        set name [clean_text $name]
        if {$name ne "" && [lsearch -exact $names $name] < 0} {
            lappend names $name
        }
    }
    return [join $names ", "]
}

proc ::rawg::format_release_date {date} {
    set date [string trim $date]
    if {$date eq ""} { return "" }
    if {[regexp {^(\d{4})-(\d{2})-(\d{2})$} $date -> year month day]} {
        if {![catch {
            set stamp [clock scan "$year-$month-$day" -format "%Y-%m-%d"]
            set date [clock format $stamp -format "%d %b %Y"]
        }]} {
            return $date
        }
    }
    return $date
}

proc ::rawg::display_value {value {fallback "N/A"}} {
    set value [string trim $value]
    if {$value eq "" || [string equal -nocase $value "null"]} {
        return $fallback
    }
    return $value
}

proc ::rawg::clean_description {value} {
    set value [string map [list "\r" " " "\n" " " "\t" " "] $value]
    regsub -all -nocase {<br\s*/?>|</p>|</div>|</li>} $value " " value
    regsub -all {<[^>]*>} $value " " value
    set value [string map [list \&nbsp\; " " \&amp\; "&" \&quot\; {"} \&#39\; "'" \&lt\; "<" \&gt\; ">"] $value]
    regsub -all {\s+} $value { } value
    return [string trim $value]
}

proc ::rawg::truncate_text {value max_length} {
    if {$max_length < 40} { set max_length 350 }
    if {[string length $value] <= $max_length} { return $value }
    set clipped [string range $value 0 [expr {$max_length - 4}]]
    set cut [string last " " $clipped]
    if {$cut > 20} { set clipped [string range $clipped 0 [expr {$cut - 1}]] }
    return "[string trim $clipped]..."
}

proc ::rawg::cache_get {key} {
    variable cfg
    variable cache

    if {!$cfg(cache_enabled) || ![info exists cache($key)]} {
        return ""
    }

    lassign $cache($key) timestamp data
    if {[clock seconds] - $timestamp > $cfg(cache_ttl)} {
        unset cache($key)
        return ""
    }
    return $data
}

proc ::rawg::cache_set {key data} {
    variable cfg
    variable cache
    if {$cfg(cache_enabled)} {
        set cache($key) [list [clock seconds] $data]
    }
}

proc ::rawg::run_callback {path callback context data} {
    log "CALLBACK START: path=$path callback=$callback bytes=[string length $data]"
    if {[catch {uplevel #0 [list $callback $context $data]} error options]} {
        log "CALLBACK ERROR: path=$path callback=$callback error=$error"
        if {[dict exists $options -errorinfo]} {
            log "CALLBACK TRACE: [dict get $options -errorinfo]"
        }
        return
    }
    log "CALLBACK END: path=$path callback=$callback"
}

proc ::rawg::schedule_callback {path callback context data} {
    after 0 [list ::rawg::run_callback $path $callback $context $data]
}

proc ::rawg::api_get {path callback context {attempt 0}} {
    variable cfg

    if {$cfg(sandbox_mode)} {
        log "SANDBOX: API request skipped: $path"
        schedule_callback $path $callback $context ""
        return
    }

    if {$cfg(api_key) eq "" || $cfg(api_key) eq "YOUR_RAWG_API_KEY"} {
        log "ERROR: Configure cfg(api_key) before making API requests."
        schedule_callback $path $callback $context ""
        return
    }

    set cached [cache_get $path]
    if {$cached ne ""} {
        log "CACHE HIT: $path"
        schedule_callback $path $callback $context $cached
        return
    }

    set separator "?"
    if {[string first "?" $path] >= 0} {
        set separator "&"
    }
    set key_query [::http::formatQuery key $cfg(api_key)]
    set url "$cfg(api_url)/$path${separator}${key_query}"

    set headers [list \
        Accept "application/json" \
        User-Agent $cfg(user_agent)]

    log "API REQUEST: $path"

    if {[catch {
        ::http::geturl $url \
            -timeout $cfg(timeout) \
            -headers $headers \
            -command [list ::rawg::http_done $path $callback $context $attempt]
    } error]} {
        log "HTTP REQUEST ERROR: $error"
        if {$attempt < $cfg(max_retries)} {
            after [expr {$cfg(retry_delay) * 1000}] \
                [list ::rawg::api_get $path $callback $context [expr {$attempt + 1}]]
        } else {
            schedule_callback $path $callback $context ""
        }
    }
}

proc ::rawg::http_done {path callback context attempt token} {
    variable cfg

    set status "unknown"
    set code 0
    set data ""

    if {[catch {set status [::http::status $token]} error]} {
        log "HTTP STATUS ERROR: path=$path error=$error"
    }
    if {[catch {set code [::http::ncode $token]} error]} {
        log "HTTP CODE ERROR: path=$path error=$error"
    }
    if {[catch {set data [::http::data $token]} error]} {
        log "HTTP DATA ERROR: path=$path error=$error"
        set data ""
    }

    set bytes [string length $data]
    log "HTTP RESPONSE: status=$status code=$code path=$path bytes=$bytes attempt=[expr {$attempt + 1}]"

    if {$status ne "ok" || $code != 200} {
        set detail ""
        if {$data ne "" && [catch {set error_dict [::json::json2dict $data]}] == 0} {
            set detail [get $error_dict detail]
            if {$detail eq ""} {
                set detail [get $error_dict message]
            }
        }
        if {$detail ne ""} {
            log "HTTP ERROR DETAIL: [clean_text $detail]"
        }
        if {$code == 401 || $code == 403} {
            log "Check the RAWG API key and account access."
        } elseif {$code == 429} {
            log "RAWG API rate limit reached (HTTP 429)."
        } elseif {$status ne "ok"} {
            log "HTTP transport failed; check DNS, TLS and network connectivity."
        } else {
            log "RAWG returned a non-success HTTP response."
        }
    }

    catch {::http::cleanup $token}

    if {$status ne "ok" || $code != 200 || $data eq ""} {
        if {$attempt < $cfg(max_retries)} {
            set next_attempt [expr {$attempt + 1}]
            log "RETRY: $path attempt [expr {$next_attempt + 1}] of [expr {$cfg(max_retries) + 1}]"
            after [expr {$cfg(retry_delay) * 1000}] \
                [list ::rawg::api_get $path $callback $context $next_attempt]
        } else {
            log "REQUEST FAILED: path=$path retries_exhausted=1"
            schedule_callback $path $callback $context ""
        }
        return
    }

    log "HTTP SUCCESS: path=$path"
    cache_set $path $data
    schedule_callback $path $callback $context $data
}

proc ::rawg::normalize_query {text} {
    return [release_to_title $text]
}

proc ::rawg::search_game {target query mode} {
    set query [normalize_query $query]
    if {$query eq ""} {
        putquick  "PRIVMSG $target :Usage: !$::rawg::cfg(gameinfo_trigger) <game name>"
        return
    }
    set encoded [::http::formatQuery search $query page_size 8]
    set path "games?$encoded"
    api_get $path ::rawg::search_done [list $target $query $mode]
}

proc ::rawg::search_done {context data} {
    lassign $context target query mode
    log "SEARCH CALLBACK: query=$query mode=$mode bytes=[string length $data]"

    if {$data eq ""} {
        putquick  "PRIVMSG $target :RAWG: No API response. Check the API key, network and log."
        return
    }

    set decoded [decode $data]
    if {$decoded eq ""} {
        putquick  "PRIVMSG $target :RAWG: Could not decode the API response."
        return
    }

    set results [get $decoded results]
    log "SEARCH PARSED: query=$query result_count=[llength $results]"
    if {[llength $results] == 0} {
        putquick  "PRIVMSG $target :RAWG: No game found for: $query"
        return
    }

    set selected ""
    set best_score -999
    foreach result $results {
        set result_name [get $result name]
        set score [search_result_score $query $result_name]
        log "SEARCH CANDIDATE: query=$query game=$result_name score=$score"
        if {$score > $best_score} {
            set best_score $score
            set selected $result
        }
    }

    if {$selected eq "" || $best_score < 0} {
        if {![string equal -nocase $mode "AUTO"]} {
            putquick "PRIVMSG $target :RAWG: No sufficiently matching game found for: $query"
        } else {
            log "AUTO SEARCH REJECTED: query=$query reason=no_main_title_match (channel notice suppressed)"
        }
        log "SEARCH REJECTED: query=$query reason=no_main_title_match"
        return
    }

    set id [get $selected id]
    log "SEARCH SELECTED: query=$query game=[get $selected name] id=$id score=$best_score"
    if {$id eq ""} {
        putquick  "PRIVMSG $target :RAWG: Search result did not contain a game ID."
        return
    }

    api_get "games/$id" ::rawg::details_done [list $target $query $mode]
}

proc ::rawg::search_result_score {query result_name} {
    set query_title [string tolower [normalize_query $query]]
    set result_title [string tolower [normalize_query $result_name]]
    if {$query_title eq "" || $result_title eq ""} { return -1 }
    if {$query_title eq $result_title} { return 10000 }

    set query_words [regexp -all -inline {[[:alnum:]]+} $query_title]
    set result_words [regexp -all -inline {[[:alnum:]]+} $result_title]
    set generic_words {the a an and or of in on to for with edition game}

    set main_word ""
    foreach word $query_words {
        if {[lsearch -exact $generic_words $word] < 0} {
            set main_word $word
            break
        }
    }

    if {$main_word eq "" || [lsearch -exact $result_words $main_word] < 0} {
        return -1
    }

    set score 500
    foreach word $query_words {
        if {$word eq $main_word} { continue }
        if {[lsearch -exact $result_words $word] >= 0} {
            incr score 100
        }
    }

    # Prefer close phrase matches when the main title keyword is present.
    if {[string first $query_title $result_title] >= 0 ||
        [string first $result_title $query_title] >= 0} {
        incr score 25
    }
    return $score
}

proc ::rawg::lookup_id {target id mode} {
    if {![string is integer -strict $id] || $id < 1} {
        putquick  "PRIVMSG $target :Usage: !gameid <numeric RAWG ID>"
        return
    }
    api_get "games/$id" ::rawg::details_done [list $target $id $mode]
}

proc ::rawg::details_done {context data} {
    lassign $context target query mode
    log "DETAILS CALLBACK: query=$query mode=$mode bytes=[string length $data]"

    if {$data eq ""} {
        putquick  "PRIVMSG $target :RAWG: No game details received."
        return
    }

    set game [decode $data]
    if {$game eq ""} {
        putquick  "PRIVMSG $target :RAWG: Could not decode game details."
        return
    }

    set game_name [clean_text [get $game name]]
    log "DETAILS PARSED: name=$game_name id=[get $game id]"
    set game_id [get $game id]
    if {$game_name eq "" || $game_id eq ""} {
        putquick  "PRIVMSG $target :RAWG: Game details are incomplete."
        return
    }

    if {$mode eq "preview"} {
        announce_game $target $game "PREVIEW"
    } elseif {$mode eq "auto"} {
        announce_game $target $game "AUTO"
    } else {
        #announce_game $target $game "INFO"
        announce_game $target $game ""
    }
}

proc ::rawg::append_field {lineVar name data} {
    upvar 1 $lineVar line
    if {$data eq ""} { return }
    set item [field $name $data]
    if {$item eq ""} { return }
    if {$line ne ""} {
        #append line " \00314-\003 " 
        append line " "
    }
    append line $item
}

proc ::rawg::send_limited {target message} {
    variable cfg
    set max $cfg(max_line_length)
    if {$max < 100} { set max 450 }
    if {[string length $message] <= $max} {
        putquick  "PRIVMSG $target :$message"
        return
    }

    set remaining $message
    while {[string length $remaining] > $max} {
        set cut [string last " " [string range $remaining 0 [expr {$max - 1}]]]
        if {$cut < 1} { set cut $max }
        putquick  "PRIVMSG $target :[string range $remaining 0 [expr {$cut - 1}]]"
        set remaining [string trim [string range $remaining $cut end]]
    }
    if {$remaining ne ""} { putquick  "PRIVMSG $target :$remaining" }
}

proc ::rawg::announce_game {target game mode} {
    variable cfg
    log "ANNOUNCEMENT BUILD: target=$target mode=$mode game=[get $game name] id=[get $game id]"

    set name [clean_text [get $game name]]
    set id [get $game id]
    set released [format_release_date [get $game released]]
    if {$released eq "" && [get $game tba] eq "true"} {
        set released "TBA"
    }
    set genres [names_from_objects [get $game genres] ""]
    set description [get $game description_raw]
    if {$description eq ""} { set description [get $game description] }
    set description [truncate_text [clean_description $description] $cfg(description_max_length)]
    set platforms [names_from_objects [get $game platforms] platform]
    set developers [names_from_objects [get $game developers] ""]
    set publishers [names_from_objects [get $game publishers] ""]
    set metacritic [display_value [get $game metacritic]]
    set rating [get $game rating]
    set esrb [get [get $game esrb_rating] name]
    set website [get $game website]
    set rawg_url "https://rawg.io/games/[get $game slug]"
    set lines {}

    set line ""
    if {$cfg(announce_header)} {
        set line "\002INFO\002 [string toupper $mode]:"
    }
    if {$cfg(show_name)} { append_field line "Game" $name }
    if {$cfg(show_rawg_id)} { append_field line "- RAWG ID" $id }
    if {$cfg(show_release)} { append_field line "- Released" $released }
    if {$cfg(show_genres)} { append_field line "- Genres" $genres }
    if {$cfg(show_platforms)} { append_field line "- Avalable on" $platforms }
    if {$cfg(show_metacritic)} { append_field line "- Metascore" $metacritic }
    if {$cfg(show_rating)} { append_field line "- Rating" \00304$rating\003/\003035.0\003 }
    if {$cfg(show_website)} { append_field line "- Link" $website }
    if {$line ne ""} { lappend lines $line }

    set line ""
    if {$cfg(announce_header_2)} {
        set line "\002INFO\002 [string toupper $mode]:"
    }
    if {$cfg(show_developers)} { append_field line "Developer" $developers }
    if {$cfg(show_publishers)} { append_field line "- Publisher" $publishers }
    if {$cfg(show_esrb)} { append_field line "- ESRB" $esrb }
    if {$cfg(show_rawg_url)} { append_field line "- Source" $rawg_url }
    if {$line ne ""} { lappend lines $line }

    set line ""
    if {$cfg(announce_header_3)} {
        set line "\002INFO\002 [string toupper $mode]:"
    }
    if {$cfg(show_description)} { append_field line "About" $description }
    if {$line ne ""} { lappend lines $line }

    lappend lines " "

    if {[llength $lines] == 0} {
        putquick  "PRIVMSG $target :RAWG: No announcement fields are enabled."
        return
    }

    log "ANNOUNCEMENT READY: target=$target mode=$mode lines=[llength $lines]"
    foreach output $lines {
        send_limited $target $output
    }
    log "ANNOUNCEMENT QUEUED: target=$target mode=$mode"
}

proc ::rawg::command_allowed {hand} {
    variable cfg
    if {$cfg(command_flags) eq "-" || $cfg(command_flags) eq ""} {
        return 1
    }
    return [matchattr $hand $cfg(command_flags)]
}

proc ::rawg::pub_gameinfo {nick host hand chan text} {
    variable cfg
    if {!$cfg(enabled)} { return }
    if {![command_allowed $hand]} {
        putquick  "PRIVMSG $chan :RAWG: You are not allowed to use this command."
        return
    }
    if {[string trim $text] eq ""} {
        putquick  "PRIVMSG $chan :Usage: !$cfg(gameinfo_trigger) <game name>"
        return
    }
    search_game $chan $text "INFO"
}

proc ::rawg::pub_gameid {nick host hand chan text} {
    variable cfg
    if {!$cfg(enabled)} { return }
    if {![command_allowed $hand]} {
        putquick  "PRIVMSG $chan :RAWG: You are not allowed to use this command."
        return
    }
    lookup_id $chan [string trim $text] "INFO"
}

proc ::rawg::pub_preview {nick host hand chan text} {
    variable cfg
    if {!$cfg(enabled) || !$cfg(preview_enabled)} { return }
    if {![command_allowed $hand]} {
        putquick  "PRIVMSG $chan :RAWG: You are not allowed to use this command."
        return
    }
    if {[string trim $text] eq ""} {
        putquick  "PRIVMSG $chan :Usage: !rawgpreview <release name>"
        return
    }
    set query [release_to_title $text]
    log "MANUAL PREVIEW: $text -> $query"
    search_game $chan $query "PREVIEW"
}

proc ::rawg::release_to_title {release} {
    set title [string trim [file tail [string map {\\ /} $release]]]
    if {$title eq ""} { return "" }
    
    set release_hyphen_count [regexp -all -- {-} $title]
    regsub -nocase -- {-(RUNE|TENOKE|DINOByTES|HOODLUM|I_KnoW|FCKDRM|Razor1911|FLT|DUPLEX|UNLiMiTED|LiGHTFORCE|SUXXORS|HR|BREWS)$} $title {} title
    if {$release_hyphen_count == 1 && [regexp {[._]} $title]} {
        regsub -nocase -- {-[a-z0-9][a-z0-9_-]*$} $title {} title
    }
    
    regsub -nocase {([._ -]+)(PS5|PS4|PS3|PS2|NSW|SWITCH|NINTENDO[._ ]SWITCH|XBOX[._ ]?(ONE|SERIES[._ ]?X|SERIES[._ ]?S)?)([._ -].*)?$} $title {} title
    regsub -nocase {[._ -]+UPDATE([._ -].*)?$} $title {} title
    regsub -nocase {[._ -]+PLUS[._ -]+[0-9]+[._ -]+TRAINER([._ -].*)?$} $title {} title
    regsub -nocase {[._ -]+(DLC[._ -]+UNLOCKER|DLC[._ -]+UNLOCK|INCL[._ -]+DLC)([._ -].*)?$} $title {} title
    regsub -nocase {[._ -]+(READNFO|REPACK|PROPER)([._ -].*)?$} $title {} title
    regsub -nocase {[._ -]+(BONUS[._ -]+CONTENT)([._ -].*)?$} $title {} title
    regsub -nocase {[._ -]+MASTER[._ -]+COLLECTION[._ -]+VERSION$} $title {} title
    regsub -nocase {[._ -]+v[0-9]+([._-][0-9a-z]+)*.*$} $title {} title
    regsub -- {[._ -]+(19[0-9]{2}|20[0-9]{2})$} $title {} title

    set title [string map [list "." " " "_" " " "-" " "] $title]
    regsub -all {\s+} $title { } title
    return [string trim $title]
}

proc ::rawg::valid_game_path {path} {
    variable cfg

    set normalized [string map {\\ /} [string trim $path]]
    set normalized [string trimright $normalized "/"]
    if {$normalized eq ""} { return 0 }

    foreach configured_root $cfg(announce_dirs) {
        set root [string map {\\ /} [string trim $configured_root]]
        set root [string trimright $root "/"]
        if {$root eq ""} { continue }

        set root_candidates [list $root]
        if {[string equal -nocase [string range $root 0 7] "/glftpd/"]} {
            lappend root_candidates [string range $root 7 end]
        }

        foreach candidate $root_candidates {
            set prefix "${candidate}/"
            if {[string equal -nocase [string range $normalized 0 [expr {[string length $prefix] - 1}]] $prefix]} {
                set release_name [string range $normalized [string length $prefix] end]
                if {$release_name ne "" && [string first "/" $release_name] < 0 && $release_name ne "." && $release_name ne ".."} {
                    return 1
                }
            }
        }
    }
    return 0
}

proc ::rawg::LogEvent {event section logData} {
    variable cfg

    if {!$cfg(enabled) || !$cfg(auto_release_enabled)} { return 1 }
    if {![string equal -nocase $event "NEWDIR"]} { return 1 }

    set fullpath [lindex $logData 0]
    if {$fullpath eq "" || ![valid_game_path $fullpath]} {
        log "IGNORED NEWDIR: section=$section path=$fullpath"
        return 1
    }

    set release [file tail $fullpath]
    set title [release_to_title $release]
    if {$title eq ""} {
        log "IGNORED: could not derive game title from $release"
        return 1
    }

    log "AUTO RELEASE: $release -> $title"
    foreach channel $cfg(auto_release_channels) {
        after [expr {$cfg(auto_release_delay) * 1000}] \
            [list ::rawg::search_game $channel $title "AUTO"]
    }
    return 1
}

proc ::rawg {event section logData} {
    return [::rawg::LogEvent $event $section $logData]
}

# -----------------------------------------------------------------------------
# SANDBOX / DIAGNOSTICS
# -----------------------------------------------------------------------------

proc ::rawg::sandbox_test {} {
    variable cfg
    log "SANDBOX TEST STARTED"
    log "API URL: $cfg(api_url)"
    log "Timeout: $cfg(timeout) ms"
    log "Retries: $cfg(max_retries)"
    log "Cache enabled: $cfg(cache_enabled)"
    log "Automatic releases: $cfg(auto_release_enabled)"
    log "Configured announcement directories: $cfg(announce_dirs)"
    log "Configured announcement channels: $cfg(auto_release_channels)"
    log "No API requests will be sent by this diagnostic."
    log "SANDBOX TEST FINISHED"
}

# -----------------------------------------------------------------------------
# INITIALIZATION AND CLEAN UNLOAD
# -----------------------------------------------------------------------------

proc ::rawg::register_pzs {{quiet 0}} {
    variable scriptName

    # PZS-NG uses the script name to resolve the global ::rawg dispatcher.
    if {[info exists ::ngBot::postcommand(NEWDIR)]} {
        if {[lsearch -exact $::ngBot::postcommand(NEWDIR) $scriptName] < 0} {
            lappend ::ngBot::postcommand(NEWDIR) $scriptName
        }
        log "Registered PZS-NG postcommand NEWDIR handler."
        return 1
    }

    if {[info exists ::ngBot::precommand(NEWDIR)]} {
        if {[lsearch -exact $::ngBot::precommand(NEWDIR) $scriptName] < 0} {
            lappend ::ngBot::precommand(NEWDIR) $scriptName
        }
        log "Registered PZS-NG precommand NEWDIR handler."
        return 1
    }

    if {!$quiet} {
        log "WARNING: PZS-NG NEWDIR command list not found; registration will be retried."
    }
    return 0
}

proc ::rawg::schedule_pzs_registration {args} {
    variable registration_timer

    if {$registration_timer eq ""} {
        set registration_timer [utimer 5 ::rawg::register_pzs_retry]
    }
}

proc ::rawg::register_pzs_retry {} {
    variable registration_timer
    variable registration_attempts

    set registration_timer ""
    if {[register_pzs 1]} {
        set registration_attempts 0
        return 1
    }

    incr registration_attempts
    if {$registration_attempts < 12} {
        log "PZS-NG NEWDIR list not ready; retry $registration_attempts/12 in 5 seconds."
        schedule_pzs_registration
    } else {
        log "WARNING: PZS-NG NEWDIR registration failed after 12 attempts; use ::rawg::register_pzs after PZS-NG loads."
    }
    return 0
}

proc ::rawg::unregister_pzs {} {
    variable scriptName
    foreach variable_name {::ngBot::postcommand(NEWDIR) ::ngBot::precommand(NEWDIR)} {
        if {[uplevel #0 [list info exists $variable_name]]} {
            set current [uplevel #0 [list set $variable_name]]
            set position [lsearch -exact $current $scriptName]
            if {$position >= 0} {
                set current [lreplace $current $position $position]
                uplevel #0 [list set $variable_name $current]
            }
        }
    }
}

proc ::rawg::unload {args} {
    variable registration_timer
    if {$registration_timer ne ""} {
        catch {killutimer $registration_timer}
        set registration_timer ""
    }
    unregister_pzs
    variable gameinfo_bound_trigger
    if {$gameinfo_bound_trigger ne ""} {
        catch {unbind pub - $gameinfo_bound_trigger ::rawg::pub_gameinfo}
        set gameinfo_bound_trigger ""
    }
    catch {unbind pub - !gameinfo ::rawg::pub_gameinfo}
    catch {unbind pub - !gameid ::rawg::pub_gameid}
    catch {unbind pub - !rawgpreview ::rawg::pub_preview}
    catch {unbind evnt - prerehash ::rawg::unload}
    catch {unbind evnt - prerestart ::rawg::unload}
    catch {unbind evnt - init-server ::rawg::schedule_pzs_registration}
    catch {::http::unregister https}
    catch {rename ::rawg {}}
    catch {namespace delete ::rawg}
    putlog "RAWG: Script unloaded."
}

proc ::rawg::init {} {
    variable cfg
    variable version

    if {!$cfg(enabled)} {
        putlog "RAWG: Script disabled in configuration."
        return
    }

    foreach package {http json tls} {
        if {[catch {package require $package} error]} {
            putlog "RAWG: ERROR loading package $package: $error"
            return
        }
    }

    # Enable HTTPS for Tcllib http.
    catch {::http::register https 443 [list ::tls::socket -autoservername 1]}

    variable gameinfo_bound_trigger
    set trigger [string trim $cfg(gameinfo_trigger)]
    if {$trigger eq "" || [regexp {\s} $trigger] || [string index $trigger 0] eq "!"} {
        putlog "RAWG: ERROR - cfg(gameinfo_trigger) must be a single command name without ! (example: gameinfo)."
        return
    }

    # Remove the previous configured binding when the script is reloaded
    # with a different trigger.
    if {$gameinfo_bound_trigger ne ""} {
        catch {unbind pub - $gameinfo_bound_trigger ::rawg::pub_gameinfo}
    }
    catch {unbind pub - !gameinfo ::rawg::pub_gameinfo}
    catch {unbind pub - !gameid ::rawg::pub_gameid}
    catch {unbind pub - !rawgpreview ::rawg::pub_preview}

    bind pub - !$trigger ::rawg::pub_gameinfo
    set gameinfo_bound_trigger "!$trigger"
    bind pub - !gameid ::rawg::pub_gameid
    bind pub - !rawgpreview ::rawg::pub_preview
    bind evnt - prerehash ::rawg::unload
    bind evnt - prerestart ::rawg::unload
    bind evnt - init-server ::rawg::schedule_pzs_registration

    # PZS-NG may initialize its command lists after RAWG is sourced.
    # Delay registration and retry briefly instead of failing on load order.
    schedule_pzs_registration

    putlog "RAWG: PZS-NG NEWDIR registration scheduled (checks every 5 seconds if needed)."
    putlog "RAWG: Loaded RAWG Game API script v$version"
    putlog "RAWG: Commands: !$trigger, !gameid, !rawgpreview"
    putlog "RAWG: HTTP callback diagnostics enabled (status, code, bytes, callback stages)."
    putlog "RAWG: Automatic announcement directories: $cfg(announce_dirs)"
    if {$cfg(api_key) eq "YOUR_RAWG_API_KEY" || $cfg(api_key) eq ""} {
        putlog "RAWG: WARNING - Set cfg(api_key) before using API commands."
    }
}

::rawg::init

# -----------------------------------------------------------------------------
# END OF SCRIPT
# -----------------------------------------------------------------------------
