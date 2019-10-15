(function(){

if (!fixmystreet.maps) {
    return;
}

var defaults = {
    http_options: {
        url: "https://tilma.staging.mysociety.org/mapserver/tfl",
        params: {
            SERVICE: "WFS",
            VERSION: "1.1.0",
            REQUEST: "GetFeature",
            SRSNAME: "urn:ogc:def:crs:EPSG::3857"
        }
    },
    asset_type: 'spot',
    max_resolution: 2.388657133579254,
    min_resolution: 0.5971642833948135,
    geometryName: 'msGeometry',
    srsName: "EPSG:3857",
    strategy_class: OpenLayers.Strategy.FixMyStreet,
    body: "TfL"
};

var asset_defaults = $.extend(true, {}, defaults, {
    select_action: true,
    no_asset_msg_id: '#js-not-an-asset',
    actions: {
        asset_found: fixmystreet.message_controller.asset_found,
        asset_not_found: fixmystreet.message_controller.asset_not_found
    }
});

fixmystreet.assets.add(asset_defaults, {
    http_options: {
        params: {
            TYPENAME: "trafficsignals"
        }
    },
    asset_id_field: 'Site',
    attributes: {
        site: 'Site',
    },
    asset_group: "Traffic Lights",
    asset_item: 'traffic signal'
});

fixmystreet.assets.add(asset_defaults, {
    http_options: {
        params: {
            TYPENAME: "busstops"
        }
    },
    asset_id_field: 'STOP_CODE',
    attributes: {
        stop_code: 'STOP_CODE',
    },
    asset_group: "Bus Stops and Shelters",
    asset_item: 'bus stop'
});


/* Red routes (TLRN) asset layer & handling for disabling form when red route
   is not selected for specific categories. */

var tlrn_stylemap = new OpenLayers.StyleMap({
    'default': new OpenLayers.Style({
        fillColor: "#ff0000",
        fillOpacity: 0.3,
        strokeColor: "#ff0000",
        strokeOpacity: 0.6,
        strokeWidth: 2
    })
});


/* Reports in these categories can only be made on a red route */
var tlrn_categories = [
    "All out - three or more street lights in a row",
    "Blocked drain",
    "Damage - general (Trees)",
    "Dead animal in the carriageway or footway",
    "Debris in the carriageway",
    "Fallen Tree",
    "Flooding",
    "Flytipping",
    "Graffiti / Flyposting (non-offensive)",
    "Graffiti / Flyposting (offensive)",
    "Graffiti / Flyposting on street light (non-offensive)",
    "Graffiti / Flyposting on street light (offensive)",
    "Grass Cutting and Hedges",
    "Hoardings blocking carriageway or footway",
    "Light on during daylight hours",
    "Lights out in Pedestrian Subway",
    "Low hanging branches and general maintenance",
    "Manhole Cover - Damaged (rocking or noisy)",
    "Manhole Cover - Missing",
    "Mobile Crane Operation",
    "Pavement Defect (uneven surface / cracked paving slab)",
    "Pothole",
    "Roadworks",
    "Scaffolding blocking carriageway or footway",
    "Single Light out (street light)",
    "Standing water",
    "Unstable hoardings",
    "Unstable scaffolding",
    "Worn out road markings"
];

var red_routes_layer = fixmystreet.assets.add(defaults, {
    http_options: {
        url: "https://tilma.mysociety.org/mapserver/tfl",
        params: {
            TYPENAME: "RedRoutes"
        }
    },
    name: "Red Routes",
    max_resolution: 9.554628534317017,
    road: true,
    non_interactive: true,
    asset_category: tlrn_categories,
    nearest_radius: 0.1,
    stylemap: tlrn_stylemap,
    no_asset_msg_id: '#js-not-tfl-road',
    actions: {
        found: fixmystreet.message_controller.road_found,
        not_found: fixmystreet.message_controller.road_not_found
    }
});
if (red_routes_layer) {
    red_routes_layer.events.register( 'loadend', red_routes_layer, function(){
        // The roadworks layer may have finished loading before this layer, so
        // ensure the filters to only show markers that intersect with a red route
        // are re-applied.
        var roadworks = fixmystreet.map.getLayersByName("Roadworks");
        if (roadworks.length) {
            // .redraw() reapplies filters without issuing any new requests
            roadworks[0].redraw();
        }
    });
}


/* Roadworks.org asset layer */

var org_id = '1250';
var body = "TfL";

var rw_stylemap = new OpenLayers.StyleMap({
    'default': new OpenLayers.Style({
        fillOpacity: 1,
        fillColor: "#FFFF00",
        strokeColor: "#000000",
        strokeOpacity: 0.8,
        strokeWidth: 2,
        pointRadius: 6,
        graphicWidth: 39,
        graphicHeight: 25,
        graphicOpacity: 1,
        externalGraphic: '/cobrands/tfl/warning@2x.png'
    }),
    'hover': new OpenLayers.Style({
        fillColor: "#55BB00",
        externalGraphic: '/cobrands/tfl/warning-green@2x.png'
    }),
    'select': new OpenLayers.Style({
        fillColor: "#55BB00",
        externalGraphic: '/cobrands/tfl/warning-green@2x.png'
    })
});

OpenLayers.Format.TfLRoadworksOrg = OpenLayers.Class(OpenLayers.Format.RoadworksOrg, {
    updateParams: function(params) {
        params.filterstartdate = fixmystreet.roadworks.format_date(new Date());
        params.filterenddate = fixmystreet.roadworks.format_date(new Date(Date.now() + (21 * 86400 * 1000)));
        return params;
    },
    convertToPoints: true,
    CLASS_NAME: "OpenLayers.Format.TfLRoadworksOrg"
});

fixmystreet.assets.add(fixmystreet.roadworks.layer_future, {
    http_options: {
        params: { organisation_id: org_id },
    },
    name: "Roadworks",
    format_class: OpenLayers.Format.TfLRoadworksOrg,
    body: body,
    non_interactive: false,
    always_visible: false,
    road: false,
    all_categories: false,
    asset_category: "Roadworks",
    stylemap: rw_stylemap,
    asset_id_field: 'promoter_works_ref',
    asset_item: 'roadworks',
    attributes: {
        promoter_works_ref: 'promoter_works_ref',
        start: 'start',
        end: 'end',
        promoter: 'promoter',
        works_desc: 'works_desc',
        works_state: function(feature) {
            return {
                1: "1", // Haven't seen this in the wild yet
                2: "Advanced planning",
                3: "Planned work about to start",
                4: "Work in progress"
            }[this.attributes.works_state] || this.attributes.works_state;
        },
        tooltip: 'tooltip'
    },
    filter_key: true,
    filter_value: function(feature) {
        var red_routes = fixmystreet.map.getLayersByName("Red Routes");
        if (!red_routes.length) {
            return false;
        }
        red_routes = red_routes[0];
        return red_routes.getFeaturesWithinDistance(feature.geometry, 10).length > 0;
    },
    select_action: true,
    actions: {
        // Need to override these two from roadworks_defaults in roadworks.js
        found: null,
        not_found: null,

        asset_found: function(feature) {
            this.fixmystreet.actions.asset_not_found.call(this);
            feature.layer = this;
            var attr = feature.attributes,
            tooltip = attr.tooltip.replace(/\\n/g, '\n'),
            desc = attr.works_desc.replace(/\\n/g, '\n');

            var $msg = $('<div class="js-roadworks-message js-roadworks-message-' + this.id + ' box-warning"></div>');
            var $dl = $("<dl></dl>").appendTo($msg);
            if (attr.promoter) {
                $dl.append("<dt>Responsibility</dt>");
                $dl.append($("<dd></dd>").text(attr.promoter));
            }
            $dl.append("<dt>Location</dt>");
            var $summary = $("<dd></dd>").appendTo($dl);
            tooltip.split("\n").forEach(function(para) {
                if (para.match(/^(\d{2}\s+\w{3}\s+(\d{2}:\d{2}\s+)?\d{4}( - )?){2}/)) {
                    // skip showing the date again
                    return;
                }
                if (para.match(/^delays/)) {
                    // skip showing traffic delay information
                    return;
                }
                $summary.append(para).append("<br />");
            });
            if (desc) {
                $dl.append("<dt>Description</dt>");
                $dl.append($("<dd></dd>").text(desc));
            }
            $dl.append("<dt>Dates</dt>");
            var $dates = $("<dd></dd>").appendTo($dl);
            $dates.text(attr.start + " until " + attr.end);
            $msg.prependTo('#js-post-category-messages');
            $('#js-post-category-messages .category_meta_message').hide();
        },
        asset_not_found: function() {
            $(".js-roadworks-message-" + this.id).remove();
            $('#js-post-category-messages .category_meta_message').show();
        }
    }

});


})();
