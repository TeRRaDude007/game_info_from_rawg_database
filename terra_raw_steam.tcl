# -----------------------------------------------------------------------------
# TeRRaDuDe RAWG+Steam Game Database lookup for PC / PlayStation / Xbox / Nintendo Switch / iOS / Android - Eggdrop Tcl Script
#
# Version: 2.0.9
#
# Changelog....:
#     - Add RAWG colour settings: rawg_use_color, rawg_color_*.
#     - Header (INFO:) has its own colour (rawg_color_header).
#     - Rating colours configurable (rawg_color_rating / _rating_max).
#     - Steam colouring stays independent (steam_use_color).
#     - All Steam settings moved into ::rawg::cfg with steam_* prefix.
#     - ::steam::cfg is now auto-populated by ::rawg::sync_steam_cfg.
#     - steam_trigger stays user-configurable (default "!steam").
#     - Steam null values now display as "N/A" instead of "null".
#     - Announce header is always "INFO:".
#     - Steam announce uses the same 3-header layout as RAWG.
#     - Fix: "invalid command name command_allowed".
#     - Steam announces now use the same layout as RAWG.
#     - Replace all putserv calls with putquick.
#   2.0.0 Alpha
#     - Merge rawg/steam into one script.
#
# Requires: Eggdrop 1.9.x, Tcl 8.6+, Tcllib http, json, tls
#
# Flow:
#     PZS-NG NEWDIR (inside announce_dirs)  ->  RAWG lookup
#     RAWG hit   ->  RAWG announce only
#     RAWG miss  ->  Steam lookup (fallback)
#     Steam hit  ->  Steam announce (RAWG layout, 3 headers)
#     Steam miss ->  no announce
#
# Command triggers:
#   <gameinfo_trigger> <name>   Search RAWG, fallback to Steam on no match
#   !gameid <RAWG ID>           Direct RAWG ID lookup
#   !rawgpreview <release>      Preview the automatic announcement
#   <steam_trigger> <name|id>   Direct Steam lookup (RAWG layout)
#
# PZS-NG:
#   Registers the global ::rawg event dispatcher as "rawg" for NEWDIR.
#   Only direct releases below the configured cfg(announce_dirs) roots
#   are handled. Other sections/paths are ignored.
#
# -----------------------------------------------------------------------------
# =============================================================================
# -----------------------------------------------------------------------------
# 0 = OFF / 1 = ON
# --------------------------- CONFIG SETUP ------------------------------------

namespace eval ::rawg {
    namespace path ::rawg

    variable version "2.0.9"
    variable scriptName "rawg"
    variable cache
    variable cfg
    variable registration_timer ""
    variable registration_attempts 0
    variable gameinfo_bound_trigger ""

    array set cfg {
        enabled                 1
        api_key                 "YouAPIkeYisHere"
        api_url                 "https://api.rawg.io/api"
        user_agent              "Eggdrop-RAWG/2.0.9"
        timeout                 12000
        max_retries             2
        retry_delay             2
        cache_enabled           1
        cache_ttl               3600

        sandbox_mode            0
        debug                   0

        auto_release_enabled    1
        auto_release_channels   {#channel}
        announce_dirs           {/glftpd/site/GAMES /glftpd/site/NSW /glftpd/site/XBOX /glftpd/site/PS4 /glftpd/site/PS5}
        auto_release_delay      0

        announce_header         1
        show_name               1
        show_rawg_id            0
        show_rating             1
        show_release            1
        show_genres             1
        show_platforms          1
        show_metacritic         1
        show_website            1

        announce_header_2       0
        show_developers         0
        show_publishers         0
        show_esrb               0
        show_rawg_url           0

        announce_header_3       1
        show_description        1
        description_max_length  250

        rawg_use_color          1
        rawg_color_label        14
        rawg_color_value        03
        rawg_color_title        03
        rawg_color_text         14
        rawg_color_url          03
        rawg_color_header       00
        rawg_color_rating       04
        rawg_color_rating_max   03

        max_line_length         450
        command_flags           "-"
        preview_enabled         1
        gameinfo_trigger        "game"

        # settings for steam
        steam_fallback_enabled  1
        steam_trigger           "!steam"
        steam_channels          {}
        steam_country           "NL"
        steam_lang              "english"
        steam_timeout           8000
        steam_cooldown          5
        steam_maxdesc           220
        steam_maxalt            3
        steam_maxshots          2
        steam_parse_release     1
        steam_show_parsed       1
        steam_show_price        1
        steam_show_discount     1
        steam_show_appid        0
        steam_show_image        0
        steam_show_screenshots  0
        steam_show_alts         0

        steam_use_color         1
        steam_color_label       14
        steam_color_value       03
        steam_color_title       03
        steam_color_text        14
        steam_color_url         03
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
    if {$cfg(debug)} { putlog "RAWG: $message" }
}

# ---------- Colour helpers ---------------------------------------------------

proc ::rawg::col {code txt} {
    variable cfg
    if {!$cfg(rawg_use_color) || $code eq ""} { return $txt }
    if {[string length $code] == 1} { set code "0$code" }
    return "\003$code$txt\003"
}

proc ::rawg::label {name} {
    variable cfg
    return [col $cfg(rawg_color_label) "${name}:"]
}

proc ::rawg::value {data} {
    variable cfg
    return [col $cfg(rawg_color_value) $data]
}

proc ::rawg::field {name data} {
    set data [string trim $data]
    if {$data eq "" || $data eq "-" || [string equal -nocase $data "null"]} {
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
    if {[catch {dict exists $object $key} exists] || !$exists} { return $default }
    if {[catch {dict get $object $key} result]} { return $default }
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
        if {$name ne "" && [lsearch -exact $names $name] < 0} { lappend names $name }
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
        }]} { return $date }
    }
    return $date
}

proc ::rawg::display_value {value {fallback "N/A"}} {
    set value [string trim $value]
    if {$value eq "" || [string equal -nocase $value "null"]} { return $fallback }
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
    if {!$cfg(cache_enabled) || ![info exists cache($key)]} { return "" }
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
    if {$cfg(cache_enabled)} { set cache($key) [list [clock seconds] $data] }
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
    if {[string first "?" $path] >= 0} { set separator "&" }
    set key_query [::http::formatQuery key $cfg(api_key)]
    set url "$cfg(api_url)/$path${separator}${key_query}"
    set headers [list Accept "application/json" User-Agent $cfg(user_agent)]
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
    set status "unknown"; set code 0; set data ""
    if {[catch {set status [::http::status $token]} error]} { log "HTTP STATUS ERROR: path=$path error=$error" }
    if {[catch {set code [::http::ncode $token]} error]}   { log "HTTP CODE ERROR: path=$path error=$error" }
    if {[catch {set data [::http::data $token]} error]}    { log "HTTP DATA ERROR: path=$path error=$error"; set data "" }
    set bytes [string length $data]
    log "HTTP RESPONSE: status=$status code=$code path=$path bytes=$bytes attempt=[expr {$attempt + 1}]"
    if {$status ne "ok" || $code != 200} {
        set detail ""
        if {$data ne "" && [catch {set error_dict [::json::json2dict $data]}] == 0} {
            set detail [get $error_dict detail]
            if {$detail eq ""} { set detail [get $error_dict message] }
        }
        if {$detail ne ""} { log "HTTP ERROR DETAIL: [clean_text $detail]" }
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
        putquick "PRIVMSG $target :Usage: !$::rawg::cfg(gameinfo_trigger) <game name>"
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
        if {$mode eq "AUTO" || $mode eq "INFO"} { steam_fallback $target $query $mode; return }
        putquick "PRIVMSG $target :RAWG: No API response. Check the API key, network and log."
        return
    }

    set decoded [decode $data]
    if {$decoded eq ""} {
        if {$mode eq "AUTO" || $mode eq "INFO"} { steam_fallback $target $query $mode; return }
        putquick "PRIVMSG $target :RAWG: Could not decode the API response."
        return
    }

    set results [get $decoded results]
    log "SEARCH PARSED: query=$query result_count=[llength $results]"

    if {[llength $results] == 0} {
        if {$mode eq "AUTO" || $mode eq "INFO"} {
            log "RAWG MISS: query=$query -> Steam fallback"
            steam_fallback $target $query $mode
            return
        }
        putquick "PRIVMSG $target :RAWG: No game found for: $query"
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
        if {$mode eq "AUTO" || $mode eq "INFO"} {
            log "RAWG REJECTED: query=$query -> Steam fallback"
            steam_fallback $target $query $mode
            return
        }
        putquick "PRIVMSG $target :RAWG: No sufficiently matching game found for: $query"
        log "SEARCH REJECTED: query=$query reason=no_main_title_match"
        return
    }

    set id [get $selected id]
    log "SEARCH SELECTED: query=$query game=[get $selected name] id=$id score=$best_score"
    if {$id eq ""} {
        if {$mode eq "AUTO" || $mode eq "INFO"} { steam_fallback $target $query $mode; return }
        putquick "PRIVMSG $target :RAWG: Search result did not contain a game ID."
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
        if {[lsearch -exact $generic_words $word] < 0} { set main_word $word; break }
    }
    if {$main_word eq "" || [lsearch -exact $result_words $main_word] < 0} { return -1 }
    set score 500
    foreach word $query_words {
        if {$word eq $main_word} { continue }
        if {[lsearch -exact $result_words $word] >= 0} { incr score 100 }
    }
    if {[string first $query_title $result_title] >= 0 ||
        [string first $result_title $query_title] >= 0} { incr score 25 }
    return $score
}

proc ::rawg::lookup_id {target id mode} {
    if {![string is integer -strict $id] || $id < 1} {
        putquick "PRIVMSG $target :Usage: !gameid <numeric RAWG ID>"
        return
    }
    api_get "games/$id" ::rawg::details_done [list $target $id $mode]
}

proc ::rawg::details_done {context data} {
    lassign $context target query mode
    log "DETAILS CALLBACK: query=$query mode=$mode bytes=[string length $data]"
    if {$data eq ""} {
        if {$mode eq "AUTO" || $mode eq "INFO"} { steam_fallback $target $query $mode; return }
        putquick "PRIVMSG $target :RAWG: No game details received."
        return
    }
    set game [decode $data]
    if {$game eq ""} {
        if {$mode eq "AUTO" || $mode eq "INFO"} { steam_fallback $target $query $mode; return }
        putquick "PRIVMSG $target :RAWG: Could not decode game details."
        return
    }
    set game_name [clean_text [get $game name]]
    set game_id [get $game id]
    log "DETAILS PARSED: name=$game_name id=$game_id"
    if {$game_name eq "" || $game_id eq ""} {
        if {$mode eq "AUTO" || $mode eq "INFO"} { steam_fallback $target $query $mode; return }
        putquick "PRIVMSG $target :RAWG: Game details are incomplete."
        return
    }

    announce_game $target $game $mode
}

proc ::rawg::append_field {lineVar name data} {
    upvar 1 $lineVar line
    if {$data eq ""} { return }
    set item [field $name $data]
    if {$item eq ""} { return }
    if {$line ne ""} { append line " " }
    append line $item
}

proc ::rawg::announce_prefix {} {
    variable cfg
    return "[col $cfg(rawg_color_header) "\002INFO\002"]:"
}

proc ::rawg::send_limited {target message} {
    variable cfg
    set max $cfg(max_line_length)
    if {$max < 100} { set max 450 }
    if {[string length $message] <= $max} {
        putquick "PRIVMSG $target :$message"
        return
    }
    set remaining $message
    while {[string length $remaining] > $max} {
        set cut [string last " " [string range $remaining 0 [expr {$max - 1}]]]
        if {$cut < 1} { set cut $max }
        putquick "PRIVMSG $target :[string range $remaining 0 [expr {$cut - 1}]]"
        set remaining [string trim [string range $remaining $cut end]]
    }
    if {$remaining ne ""} { putquick "PRIVMSG $target :$remaining" }
}

proc ::rawg::announce_game {target game mode} {
    variable cfg
    log "ANNOUNCEMENT BUILD: target=$target mode=$mode game=[get $game name] id=[get $game id]"

    set name [clean_text [get $game name]]
    set id [get $game id]
    set released [format_release_date [get $game released]]
    if {$released eq "" && [get $game tba] eq "true"} { set released "TBA" }
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
    if {$cfg(announce_header)} { set line [announce_prefix] }
    if {$cfg(show_name)}        { append_field line "Game" $name }
    if {$cfg(show_rawg_id)}     { append_field line "- RAWG ID" $id }
    if {$cfg(show_release)}     { append_field line "- Released" $released }
    if {$cfg(show_genres)}      { append_field line "- Genres" $genres }
    if {$cfg(show_platforms)}   { append_field line "- Available on" $platforms }
    if {$cfg(show_metacritic)}  { append_field line "- Metascore" $metacritic }
    if {$cfg(show_rating) && $rating ne ""} {
        set rtxt "[col $cfg(rawg_color_rating) $rating][col $cfg(rawg_color_rating_max) /5.0]"
        append_field line "- Rating" $rtxt
    }
    if {$cfg(show_website)}     { append_field line "- Link" $website }
    if {$line ne ""} { lappend lines $line }

    set line ""
    if {$cfg(announce_header_2)} { set line [announce_prefix] }
    if {$cfg(show_developers)}   { append_field line "Developer" $developers }
    if {$cfg(show_publishers)}   { append_field line "- Publisher" $publishers }
    if {$cfg(show_esrb)}         { append_field line "- ESRB" $esrb }
    if {$cfg(show_rawg_url)}     { append_field line "- Source" $rawg_url }
    if {$line ne ""} { lappend lines $line }

    set line ""
    if {$cfg(announce_header_3)} { set line [announce_prefix] }
    if {$cfg(show_description)}  { append_field line "About" $description }
    if {$line ne ""} { lappend lines $line }

    lappend lines " "
    if {[llength $lines] == 0} {
        putquick "PRIVMSG $target :RAWG: No announcement fields are enabled."
        return
    }

    log "ANNOUNCEMENT READY: target=$target mode=$mode lines=[llength $lines]"
    foreach output $lines { send_limited $target $output }
    log "ANNOUNCEMENT QUEUED: target=$target mode=$mode"
}

# ---------- Steam -> RAWG-style helpers (3-header layout) --------------------

proc ::rawg::nnv {value} {
    set value [string trim $value]
    if {$value eq "" || [string equal -nocase $value "null"]} { return "N/A" }
    return $value
}

proc ::rawg::steam_to_fields {g appid} {
    set name [::steam::clean [dict get $g name]]

    set released ""
    if {[dict exists $g release_date]} {
        set rd [dict get $g release_date]
        if {[dict exists $rd date]} { set released [dict get $rd date] }
    }
    set released [nnv $released]

    set genres ""
    if {[dict exists $g genres]} {
        set gl {}
        foreach x [dict get $g genres] { lappend gl [dict get $x description] }
        set genres [join $gl ", "]
    }
    set genres [nnv $genres]

    set platforms ""
    if {[dict exists $g platforms]} {
        set pl {}
        dict for {k v} [dict get $g platforms] {
            if {$v} {
                switch -- $k {
                    windows { lappend pl "PC" }
                    mac     { lappend pl "macOS" }
                    linux   { lappend pl "Linux" }
                    default { lappend pl $k }
                }
            }
        }
        set platforms [join $pl ", "]
    }
    set platforms [nnv $platforms]

    set developers ""
    if {[dict exists $g developers]} {
        set developers [join [dict get $g developers] ", "]
    }
    set developers [nnv $developers]

    set publishers ""
    if {[dict exists $g publishers]} {
        set publishers [join [dict get $g publishers] ", "]
    }
    set publishers [nnv $publishers]

    set metacritic ""
    if {[dict exists $g metacritic]} {
        set metacritic [dict get [dict get $g metacritic] score]
    }
    set metacritic [nnv $metacritic]

    set description ""
    if {[dict exists $g short_description]} {
        set description [::steam::clean [dict get $g short_description]]
    }
    set description [nnv $description]

    set website ""
    if {[dict exists $g website]} { set website [dict get $g website] }
    set website [nnv $website]

    return [dict create \
        name         $name \
        released     $released \
        genres       $genres \
        platforms    $platforms \
        developers   $developers \
        publishers   $publishers \
        metacritic   $metacritic \
        description  $description \
        website      $website \
        appid        $appid]
}

proc ::rawg::steam_price_string {g} {
    variable cfg
    if {[dict exists $g is_free] && [dict get $g is_free]} {
        return "Free"
    }
    if {![dict exists $g price_overview]} { return "" }
    set p [dict get $g price_overview]
    if {![dict exists $p final_formatted]} { return "" }
    set s [dict get $p final_formatted]
    if {$cfg(steam_show_discount) && [dict exists $p discount_percent] \
            && [dict get $p discount_percent] > 0} {
        append s " (-[dict get $p discount_percent]%, was [dict get $p initial_formatted])"
    }
    return $s
}

proc ::rawg::announce_steam_like {target g mode appid {alts {}}} {
    variable cfg
    set f [steam_to_fields $g $appid]

    set name        [dict get $f name]
    set released    [dict get $f released]
    set genres      [dict get $f genres]
    set platforms   [dict get $f platforms]
    set developers  [dict get $f developers]
    set publishers  [dict get $f publishers]
    set metacritic  [dict get $f metacritic]
    set description [dict get $f description]
    set website     [dict get $f website]

    set description [truncate_text $description $cfg(steam_maxdesc)]
    set lines {}

    set line ""
    if {$cfg(announce_header)} { set line [announce_prefix] }
    if {$cfg(show_name)}        { append_field line "Game" $name }
    if {$cfg(steam_show_appid)} { append_field line "- App ID" $appid }
    if {$cfg(show_release)}     { append_field line "- Released" $released }
    if {$cfg(show_genres)}      { append_field line "- Genres" $genres }
    if {$cfg(show_platforms)}   { append_field line "- Avalable on" $platforms }
    if {$cfg(show_metacritic)}  { append_field line "- Metascore" $metacritic }
    if {$cfg(steam_show_price)} {
        set price [steam_price_string $g]
        if {$price ne ""} { append_field line "- Price" $price }
    }
    if {$cfg(show_website)}     { append_field line "- Link" $website }
    if {$line ne ""} { lappend lines $line }

    set line ""
    if {$cfg(announce_header_2)} { set line [announce_prefix] }
    if {$cfg(show_developers)}   { append_field line "Developer" $developers }
    if {$cfg(show_publishers)}   { append_field line "- Publisher" $publishers }
    if {$cfg(steam_show_image) && [dict exists $g header_image]} {
        append_field line "- Image" [::steam::nostrip [dict get $g header_image]]
    }
    if {$cfg(steam_show_screenshots) && [dict exists $g screenshots]} {
        set shots {}
        foreach s [lrange [dict get $g screenshots] 0 [expr {$cfg(steam_maxshots) - 1}]] {
            if {[dict exists $s path_full]} { lappend shots [::steam::nostrip [dict get $s path_full]] }
        }
        if {[llength $shots]} { append_field line "- Screenshots" [join $shots " "] }
    }
    if {$line ne ""} { lappend lines $line }

    set line ""
    if {$cfg(announce_header_3)} { set line [announce_prefix] }
    if {$cfg(show_description)}  { append_field line "About" $description }
    if {$cfg(steam_show_alts) && [llength $alts]} {
        append_field line "- Also found" [join $alts ", "]
    }
    if {$line ne ""} { lappend lines $line }

    lappend lines " "

    if {[llength $lines] == 0} {
        putquick "PRIVMSG $target :RAWG: No announcement fields are enabled."
        return
    }

    foreach output $lines { send_limited $target $output }
}

proc ::rawg::command_allowed {hand} {
    variable cfg
    if {$cfg(command_flags) eq "-" || $cfg(command_flags) eq ""} { return 1 }
    return [matchattr $hand $cfg(command_flags)]
}

proc ::rawg::pub_gameinfo {nick host hand chan text} {
    variable cfg
    if {!$cfg(enabled)} { return }
    if {![::rawg::command_allowed $hand]} {
        putquick "PRIVMSG $chan :RAWG: You are not allowed to use this command."
        return
    }
    if {[string trim $text] eq ""} {
        putquick "PRIVMSG $chan :Usage: !$cfg(gameinfo_trigger) <game name>"
        return
    }
    search_game $chan $text "INFO"
}

proc ::rawg::pub_gameid {nick host hand chan text} {
    variable cfg
    if {!$cfg(enabled)} { return }
    if {![::rawg::command_allowed $hand]} {
        putquick "PRIVMSG $chan :RAWG: You are not allowed to use this command."
        return
    }
    lookup_id $chan [string trim $text] "INFO"
}

proc ::rawg::pub_preview {nick host hand chan text} {
    variable cfg
    if {!$cfg(enabled) || !$cfg(preview_enabled)} { return }
    if {![::rawg::command_allowed $hand]} {
        putquick "PRIVMSG $chan :RAWG: You are not allowed to use this command."
        return
    }
    if {[string trim $text] eq ""} {
        putquick "PRIVMSG $chan :Usage: !rawgpreview <release name>"
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
    log "RAWG colours: use=$cfg(rawg_use_color) label=$cfg(rawg_color_label) value=$cfg(rawg_color_value) header=$cfg(rawg_color_header) rating=$cfg(rawg_color_rating) rating_max=$cfg(rawg_color_rating_max)"
    log "Steam fallback enabled: $cfg(steam_fallback_enabled)"
    log "Steam trigger: $cfg(steam_trigger)"
    log "Steam channels: $cfg(steam_channels)"
    log "Steam country: $cfg(steam_country) lang: $cfg(steam_lang)"
    log "Steam timeout: $cfg(steam_timeout) cooldown: $cfg(steam_cooldown)"
    log "Steam extras: appid=$cfg(steam_show_appid) price=$cfg(steam_show_price) discount=$cfg(steam_show_discount) image=$cfg(steam_show_image) shots=$cfg(steam_show_screenshots) alts=$cfg(steam_show_alts)"
    log "Steam colours: use=$cfg(steam_use_color) label=$cfg(steam_color_label) value=$cfg(steam_color_value)"
    log "No API requests will be sent by this diagnostic."
    log "SANDBOX TEST FINISHED"
}

proc ::rawg::register_pzs {{quiet 0}} {
    variable scriptName
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

# =============================================================================
# =======================  STEAM MODULE DONT EDiTH  ===========================
# =============================================================================

namespace eval ::steam {
    namespace path ::steam

    variable cfg [dict create]
    variable version "1.7"
    variable lastuse
    array set lastuse {}
}

proc ::rawg::sync_steam_cfg {} {
    variable cfg
    set ::steam::cfg [dict create \
        channels        $cfg(steam_channels) \
        trigger         $cfg(steam_trigger) \
        country         $cfg(steam_country) \
        lang            $cfg(steam_lang) \
        timeout         $cfg(steam_timeout) \
        cooldown        $cfg(steam_cooldown) \
        maxdesc         $cfg(steam_maxdesc) \
        maxalt          $cfg(steam_maxalt) \
        maxshots        $cfg(steam_maxshots) \
        use_color       $cfg(steam_use_color) \
        color_label     $cfg(steam_color_label) \
        color_value     $cfg(steam_color_value) \
        color_title     $cfg(steam_color_title) \
        color_text      $cfg(steam_color_text) \
        color_url       $cfg(steam_color_url) \
        parse_release   $cfg(steam_parse_release) \
        show_parsed     $cfg(steam_show_parsed) \
    ]
}

proc ::steam::opt {key} {
    variable cfg
    return [dict get $cfg $key]
}

proc ::steam::fetch {url} {
    if {[catch {::http::geturl $url -timeout [opt timeout] -binary 1} tok]} {
        return -code error $tok
    }
    set status [::http::status $tok]
    set ncode  [::http::ncode $tok]
    set data   [::http::data $tok]
    ::http::cleanup $tok
    if {$status ne "ok" || $ncode != 200} {
        return -code error "HTTP $status $ncode"
    }
    return [encoding convertfrom utf-8 $data]
}

proc ::steam::clean {txt} {
    regsub -all {<[^>]*>} $txt " " txt
    set txt [string map [list \
        "&quot;" "\"" "&amp;" "&" "&lt;" "<" "&gt;" ">" \
        "&#39;" "'" "&nbsp;" " " "\r" " " "\n" " " "\t" " "] $txt]
    regsub -all {\s+} $txt " " txt
    return [string trim $txt]
}

proc ::steam::release_to_title {term} {
    if {[string first " " $term] >= 0 || ![regexp {[._].*[._]} $term]} {
        return $term
    }
    set t $term
    regsub -- {-[A-Za-z0-9]+$} $t {} t
    regsub -all {[._]+} $t " " t
    set plain [string trim $t]
    set junk {v\d+|build|update|multi\d*|repack|proper|readnfo|internal|cracked|incl|dlc|gog|linux|macos|x64|x86|iso|rip|retail|preload|hotfix|patch}
    regsub -nocase "\\y(?:$junk)\\y.*\$" $t {} t
    set t [string trim $t]
    if {$t eq ""} { return $plain }
    return $t
}

proc ::steam::search {term} {
    set q [::http::formatQuery term $term l [opt lang] cc [opt country]]
    set raw [fetch "https://store.steampowered.com/api/storesearch/?$q"]
    set d [::json::json2dict $raw]
    if {![dict exists $d items]} { return {} }
    return [dict get $d items]
}

proc ::steam::details {appid} {
    set q [::http::formatQuery appids $appid l [opt lang] cc [opt country]]
    set raw [fetch "https://store.steampowered.com/api/appdetails?$q"]
    set d [::json::json2dict $raw]
    if {![dict exists $d $appid]} { return {} }
    set entry [dict get $d $appid]
    if {![dict exists $entry success] || ![dict get $entry success]} { return {} }
    return [dict get $entry data]
}

proc ::steam::nostrip {url} { return [lindex [split $url ?] 0] }

proc ::steam::chan_allowed {chan} {
    set list [opt channels]
    if {[llength $list] == 0} { return 1 }
    return [expr {[lsearch -exact [string tolower $list] [string tolower $chan]] >= 0}]
}

proc ::steam::pub {nick uhost hand chan text} {
    variable lastuse
    if {![::steam::chan_allowed $chan]} { return 0 }

    set term [string trim $text]
    if {$term eq ""} {
        putquick "PRIVMSG $chan :Usage: [opt trigger] <game name or App ID>"
        return 1
    }

    set now [clock seconds]
    if {[info exists lastuse($chan)] && ($now - $lastuse($chan)) < [opt cooldown]} {
        return 1
    }
    set lastuse($chan) $now

    set alts {}
    if {[string is integer -strict $term]} {
        set appid $term
    } else {
        if {[opt parse_release]} { set term [::steam::release_to_title $term] }
        if {[catch {::steam::search $term} items]} {
            putquick "PRIVMSG $chan :Steam search failed: $items"
            return 1
        }
        if {[llength $items] == 0} {
            putquick "PRIVMSG $chan :No results for '$term'."
            return 1
        }
        set appid [dict get [lindex $items 0] id]
        foreach it [lrange $items 1 [opt maxalt]] {
            lappend alts "[dict get $it name] ([dict get $it id])"
        }
    }

    if {[catch {::steam::details $appid} g] || [llength $g] == 0} {
        putquick "PRIVMSG $chan :No details available for App ID $appid."
        return 1
    }

    ::rawg::announce_steam_like $chan $g "" $appid $alts
    return 1
}

proc ::rawg::steam_fallback {target query mode} {
    variable cfg
    if {!$cfg(steam_fallback_enabled)} {
        if {$mode eq "INFO"} {
            putquick "PRIVMSG $target :RAWG: No results found for: $query"
        }
        return
    }

    if {[catch {::steam::search $query} items]} {
        log "STEAM FALLBACK: search failed: $items"
        if {$mode eq "INFO"} {
            putquick "PRIVMSG $target :RAWG: No results found for: $query"
        }
        return
    }

    if {[llength $items] == 0} {
        log "STEAM FALLBACK: no results for $query"
        return
    }

    set appid [dict get [lindex $items 0] id]
    if {[catch {::steam::details $appid} g] || [llength $g] == 0} {
        log "STEAM FALLBACK: details failed for appid=$appid"
        if {$mode eq "INFO"} {
            putquick "PRIVMSG $target :RAWG: No results found for: $query"
        }
        return
    }

    set alts {}
    foreach it [lrange $items 1 $cfg(steam_maxalt)] {
        lappend alts "[dict get $it name] ([dict get $it id])"
    }

    log "STEAM FALLBACK HIT: query=$query appid=$appid"
    announce_steam_like $target $g $mode $appid $alts
}

# =============================================================================
# ==========================  INIT / UNLOAD  ==================================
# =============================================================================

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
    catch {unbind pub - [::steam::opt trigger] ::steam::pub}
    catch {unbind evnt - prerehash ::rawg::unload}
    catch {unbind evnt - prerestart ::rawg::unload}
    catch {unbind evnt - init-server ::rawg::schedule_pzs_registration}
    catch {::http::unregister https}
    catch {rename ::rawg {}}
    catch {namespace delete ::rawg}
    catch {namespace delete ::steam}
    putlog "RAWG+Steam: Script unloaded."
}

proc ::rawg::init {} {
    variable cfg
    variable version

    if {!$cfg(enabled)} {
        putlog "RAWG+Steam: Script disabled in configuration."
        return
    }

    foreach package {http json tls} {
        if {[catch {package require $package} error]} {
            putlog "RAWG+Steam: ERROR loading package $package: $error"
            return
        }
    }

    catch {::http::register https 443 [list ::tls::socket -autoservername 1]}

    sync_steam_cfg

    variable gameinfo_bound_trigger
    set trigger [string trim $cfg(gameinfo_trigger)]
    if {$trigger eq "" || [regexp {\s} $trigger] || [string index $trigger 0] eq "!"} {
        putlog "RAWG+Steam: ERROR - cfg(gameinfo_trigger) must be a single command name without ! (example: gameinfo)."
        return
    }

    set steam_trigger [string trim $cfg(steam_trigger)]
    if {$steam_trigger eq "" || [regexp {\s} $steam_trigger] || [string index $steam_trigger 0] ne "!"} {
        putlog "RAWG+Steam: ERROR - cfg(steam_trigger) must be a single command name with leading ! (example: !steam)."
        return
    }

    if {$gameinfo_bound_trigger ne ""} {
        catch {unbind pub - $gameinfo_bound_trigger ::rawg::pub_gameinfo}
    }
    catch {unbind pub - !gameinfo ::rawg::pub_gameinfo}
    catch {unbind pub - !gameid ::rawg::pub_gameid}
    catch {unbind pub - !rawgpreview ::rawg::pub_preview}
    catch {unbind pub - $steam_trigger ::steam::pub}

    bind pub - !$trigger ::rawg::pub_gameinfo
    set gameinfo_bound_trigger "!$trigger"
    bind pub - !gameid ::rawg::pub_gameid
    bind pub - !rawgpreview ::rawg::pub_preview
    bind pub - $steam_trigger ::steam::pub
    bind evnt - prerehash ::rawg::unload
    bind evnt - prerestart ::rawg::unload
    bind evnt - init-server ::rawg::schedule_pzs_registration

    schedule_pzs_registration

    putlog "RAWG+Steam: PZS-NG NEWDIR registration scheduled (checks every 5 seconds if needed)."
    putlog "RAWG+Steam: Loaded merged script v$version (putquick mode)"
    putlog "RAWG+Steam: Commands: !$trigger, !gameid, !rawgpreview, $steam_trigger"
    putlog "RAWG+Steam: Automatic announcement directories: $cfg(announce_dirs)"
    putlog "RAWG+Steam: Steam fallback: [expr {$cfg(steam_fallback_enabled) ? "enabled" : "disabled"}]"
    putlog "RAWG+Steam: RAWG colours: use=$cfg(rawg_use_color) label=$cfg(rawg_color_label) value=$cfg(rawg_color_value) header=$cfg(rawg_color_header)"
    putlog "RAWG+Steam: Steam extras: appid=$cfg(steam_show_appid) price=$cfg(steam_show_price) discount=$cfg(steam_show_discount) image=$cfg(steam_show_image) shots=$cfg(steam_show_screenshots) alts=$cfg(steam_show_alts)"
    putlog "RAWG+Steam: Steam region: $cfg(steam_country) lang=$cfg(steam_lang) timeout=$cfg(steam_timeout)ms cooldown=$cfg(steam_cooldown)s"
    if {$cfg(api_key) eq "YOUR_RAWG_API_KEY_HERE" || $cfg(api_key) eq ""} {
        putlog "RAWG+Steam: WARNING - Set cfg(api_key) before using RAWG API commands."
    }
}

::rawg::init

# -----------------------------------------------------------------------------
# END OF SCRIPT
# -----------------------------------------------------------------------------
