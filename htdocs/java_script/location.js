var MAGIC_RACK   = 0x10;
var MAGIC_HIDDEN = 0x20;

var FIB_FRONT    = 0x01;
var FIB_INTERIOR = 0x02;
var FIB_BACK     = 0x04;

var netdot_path;
var LOS = {};
var LOT = [];

var locs = {};
var view_loc_id = null;
var select_id = null;
var visible_id = null;
var select_vsize = null;
var select_hsize = null;

var remote_post = function(obj, func)
{
    jQuery.post("/netdot/rest/location", {"object" : JSON.stringify(obj)}, function (r) {
	func(r);
    }, "json");
};

var updateURLParameter = function(url, param, paramVal) {
    var newAdditionalURL = "";
    var tempArray = url.split("?");
    var baseURL = tempArray[0];
    var additionalURL = tempArray[1];
    var temp = "";
    if (additionalURL) {
        tempArray = additionalURL.split("&");
        for (i=0; i<tempArray.length; i++){
            if(tempArray[i].split('=')[0] != param){
                newAdditionalURL += temp + tempArray[i];
                temp = "&";
            }
        }
    }

    var rows_txt = temp + "" + param + "=" + paramVal;
    return baseURL + "?" + newAdditionalURL + rows_txt;
}

var LocationOptionSpec = function(los) {
	this.defvalue      = los.defvalue;
	this.description   = los.description;
	this.id            = los.id;
	this.location_type = los.location_type;
	this.maxint        = los.maxint;
	this.minint        = los.minint;
	this.name          = los.name;
	this.option_type   = los.option_type;
	this.selection     = los.selection;
	this.validator     = los.validator;
	LOS[this.id] = this;
};

LocationOptionSpec.prototype.view = function () {
    if (this.option_type == "text") {
	return new ViewTextField(this.description, this.defvalue);
    } else if (this.option_type == "int") {
	return new ViewTextField(this.description, this.defvalue);
    } else if (this.option_type == "bool") {
	return new ViewTextField(this.description, this.defvalue ? "yes" : "no");
    } else if (this.option_type == "select") {
	var val = this.defvalue;
	if (!val) {
	    var sel = this.selection.split("|");
	    val = sel[0];
	}
	return new ViewTextField(this.description, val);
    }
};

LocationOptionSpec.prototype.edit = function () {
    if (this.option_type == "text") {
	return new EditTextField(this.description, this.defvalue);
    } else if (this.option_type == "int") {
	return new EditTextField(this.description, this.defvalue);
    } else if (this.option_type == "bool") {
	return new EditTextField(this.description, this.defvalue ? "yes" : "no");
	// return new EditBoolField(this.description, this.defvalue);
    } else if (this.option_type == "select") {
	var val = this.defvalue;
	var sel = this.selection.split("|");
	if (!val) {
	    val = sel[0];
	}
	return new EditSelectField(this.description, sel, val);
    }
};

var Location = function(loc) {
	this.loc = loc;
	this.los = {};

	for (var i in LOS) {
		if (LOS[i] && LOS[i].location_type == loc.location_type.id) {
			this.los[LOS[i].id] = LOS[i];
		}
	}
	this.is_rack = this.loc.location_type.magic & MAGIC_RACK;
	this.is_root = this.loc.id == 0;

	if (this.is_rack) {
		var rack_size_id = 0;
		var rack_direction_id = 0;
		for (var i = 0; i < loc.possible_options.length; i++) {
			if (loc.possible_options[i].name == "size") {
				rack_size_id = loc.possible_options[i].id;
				this.rack_size = loc.possible_options[i].defvalue;
			}
			if (loc.possible_options[i].name == "direction") {
				rack_direction_id = loc.possible_options[i].id;
				this.rack_downwards = loc.possible_options[i].defvalue == "downwards";
			}
		}
		for (var i = 0; i < loc.options.length; i++) {
			if (loc.options[i].option_spec_id == rack_size_id) {
				this.rack_size = loc.options[i].value;
			}
			if (loc.options[i].option_spec_id == rack_direction_id) {
				this.rack_downwards = loc.options[i].value == "downwards";
			}
		}
	}
};

Location.prototype.list = function ($div) {
    var $row = $("<div class='location_row'></div>");
    var $type = $("<span class='location_col type'><a href='#'></a></span>");
    var $name = $("<span class='location_col name'><a href='#'></a></span>");
    $type.find("a").text(this.loc.location_type.name);
    $name.find("a").text(this.loc.name);
    $row.append($type);
    $row.append($name);
    $div.append($row);
    $row.find("a").click(function () {
	this.view($("#bottom_panel"));
	return false;
    }.bind(this));
};

Location.prototype.view = function ($div, opts) {
    this.opts = opts;
    var $title     = $div.find(".containerheadleft");
    var $menu      = $div.find(".containerheadright");
    var $container = $div.find(".containerbody");

    $title.text("Location information");

    $menu.empty();
    if (!this.is_root && !select_id) {
	$menu.append("<a class='edit' href='#'>[edit]</a>");
	$menu.find("a.edit").click(function () {
	    this.edit($div);
	    return false;
	}.bind(this));
	$menu.append("&nbsp;");
    }
    if (!this.is_rack) {
	$menu.append("<a class='new' href='#'>[new]</a>");
	$menu.find("a.new").click(function () {
	    this.create($div);
	    return false;
	}.bind(this));
    }

    $container.empty();
    var $tab = $("<div class='location_view'></div>");
    var $type = $("<div class='vtf'>" +
	"<span class='vtf_descr'></span>" +
	"<span class='vtf_val'></span>" +
	"</div>");
    $type.find(".vtf_descr").text("Location type");
    $type.find(".vtf_val").text(this.loc.location_type.name);
    $tab.append($type);

    var $name = $("<div class='vtf'>" +
	"<span class='vtf_descr'></span>" +
	"<span class='vtf_val'></span>" +
	"</div>");
    $name.find(".vtf_descr").text("Location name");
    $name.find(".vtf_val").text(this.loc.name);
    $tab.append($name);

    var $info = $("<div class='vtf'>" +
	"<span class='vtf_descr'></span>" +
	"<div class='vtf_val'></span>" +
	"</div>");
    $info.find(".vtf_descr").text("Location info");
    $info.find(".vtf_val").text(this.loc.info === null ? "" : this.loc.info);
    $tab.append($info);

    this.fields = {};
    for (var i in this.los) {
	this.fields[i] = this.los[i].view();
    }
    var o = this.loc.options;
    for (var i = 0; i < o.length; i++) {
	this.fields[o[i].option_spec_id].val(o[i].value);
    }

    for (var i in this.fields) {
	$tab.append(this.fields[i].obj());
    }

    $container.append($tab);

    var $assets_list;
    if (this.loc.assets.length) {
	var $list = $("<div class='location_list'></div>");
	var $head = $("<div class='location_row header'></div>");
	$head.append("<span class='location_col type'><b>Assets at this location</b></span>");
	$list.append($head);
	for (var i = 0; i < this.loc.assets.length; i++) {
	    var as = this.loc.assets[i];
	    (function (){
		var url = netdot_path +
		    "management/view.html?showheader=0&table=Asset&dowindow=1&id=" +
		    as.id;
		var $a = $("<a href='#'></a>");
		$a.text(as.label);
		$a.attr("title", as.label);
		$a.click(function () {
		    openwindow(url);
		    return false;
		});
		var $row = $("<div class='location_row'></div>");
		var $col = $("<span class='location_col type'></span>");
		$col.append($a);
		$row.append($col);
		$list.append($row);
	    }());
	}
	$assets_list = $list;
    }

    if (this.is_rack) {
	$container.append("<br/>");
	$container.append("Rack diagram");
	$container.append("<br/>");

	if (select_id && select_vsize && select_hsize) {
	    $container.append("<br/>");
	    $container.append("<span>Select a new position in the rack and press submit</span>");
	    $container.append("<br/>");
	    $container.append("<input class='submit btn' type='submit' value='Submit'/>");
	    $container.find(".submit").click(function () {
		var pid = $('input[name=rackpos]:checked', $container).val();
		if (!pid) return false;
		var $sel = $("#" + select_id, window.opener.document);
		$sel.val(pid);
		if (visible_id) {
		    var $a = $("#" + visible_id, window.opener.document);
		    $a.text(this.loc.rack_pos_labels[pid]);
		}
		window.close();
		return false;
	    }.bind(this));
	    $container.append(" ");
	}

	if (select_id) {
	    var button_text;
	    if (select_vsize && select_hsize) {
		button_text = '... or just assign the asset to the rack';
	    } else {
		button_text = 'Assign this location to the asset';
	    }
	    $container.append("<input class='submit btn' type='submit' value='" + button_text + "'/>");
	    $container.find(".submit").click(function () {
		var $sel = $("#" + select_id, window.opener.document);
		$sel.val(this.loc.id);
		if (visible_id) {
		    var $a = $("#" + visible_id, window.opener.document);
		    $a.text(this.loc.label);
		}
		window.close();
		return false;
	    }.bind(this));

	    $container.append(" ");
	    $container.append("<input class='cancel btn' type='button' value='Cancel'/>");
	    $container.find(".cancel").click(function () {
		window.close();
		return false;
	    });
	    $container.append("<br/>");
	    $container.append("<br/>");
	}

	if (this.loc.assets.length) {
	    $container.append($assets_list);
	}

	var $rack_table = this.view_rack_table(this.loc);
	$container.append($rack_table);
    } else {
	if (select_id && !this.is_root) {
	    $container.append("<br/>");
	    $container.append("<input class='submit btn' type='submit' value='Assign this location to the asset'/>");
	    $container.find(".submit").click(function () {
		var $sel = $("#" + select_id, window.opener.document);
		$sel.val(this.loc.id);
		if (visible_id) {
		    var $a = $("#" + visible_id, window.opener.document);
		    $a.text(this.loc.label);
		}
		window.close();
		return false;
	    }.bind(this));

	    $container.append(" ");
	    $container.append("<input class='cancel btn' type='button' value='Cancel'/>");
	    $container.find(".cancel").click(function () {
		window.close();
		return false;
	    });
	    $container.append("<br/>");
	}
	$container.append("<br/>");

	if (this.loc.assets.length) {
	    $container.append($assets_list);
	} else {
	    $container.append("<span>There are no assets at this location</span>");
	}

	if (this.loc.racks && this.loc.racks.length) {
	    if (this.loc.racks.length == 1)
		$container.append("<br/><span>There is <b>1</b> rack at this location</span><br/>");
	    else
		$container.append("<br/><span>There are <b>" + this.loc.racks.length + "</b> racks at this location</span><br/>");
	    var $racks = $("<div class='manyracks'></div>");
	    for (var i = 0; i < this.loc.racks.length; i++) {
		var $rack_table = this.view_rack_table(this.loc.racks[i], {with_rack_link: true, disable_rack_select: true});
		$racks.append($rack_table);
	    }
	    $container.append($racks);
	}

    }

    // http://localhost:8008/netdot/management/view.html?showheader=0&table=Asset&id=1&dowindow=1

    $div.show();
};

Location.prototype.view_rack_table = function (loc, o) {
    var L = new Location(loc);

    var $rack_table = $("<table class='rack_diagram'></table>");
    var $rack = $("<tbody></tbody>");
    $rack_table.append($rack);

    var opt = o ? o : {};

    var occupied = {};
    var FIBS = {};
    var assets = {};
    FIBS[FIB_FRONT] = "front";
    FIBS[FIB_INTERIOR] = "interior";
    FIBS[FIB_BACK] = "back";

    for (var i = 0; i < loc.assets.length; i++) {
	var as = loc.assets[i];
	assets[as.id] = as;
	as.handled = false;
	if (as.position > 0) {

	    for (var fib in FIBS) {
		if (as.fib & fib) {
		    if (!occupied[as.position])
			occupied[as.position] = {};
		    occupied[as.position][fib] = {
			"as" : as.id,
			"colspan" : as.hsize,
			"rowspan" : as.vsize,
			// "highlight" : this.opts && this.opts.highlight && this.opts.highlight == as.location_id
			"highlight" : view_loc_id && view_loc_id == as.location_id
		    };
		}

		if (L.rack_downwards) {
		    for (var k = 1; k < as.vsize; k++) {
			if (!occupied[0+as.position-k])
			    occupied[0+as.position-k] = {};
			if (as.fib & fib)
			    occupied[0+as.position-k][fib] = {
				"as" : as.id,
				"colspan" : as.hsize,
				"rowspan" : as.vsize,
				// "highlight" : this.opts && this.opts.highlight && this.opts.highlight == as.location_id
				"highlight" : view_loc_id && view_loc_id == as.location_id
			    };
		    }
		} else {
		    for (var k = 1; k < as.vsize; k++) {
			if (!occupied[0+as.position+k])
			    occupied[0+as.position+k] = {};
			if (as.fib & fib)
			    occupied[0+as.position+k][fib] = {
				"as" : as.id,
				"colspan" : as.hsize,
				"rowspan" : as.vsize,
				// "highlight" : this.opts && this.opts.highlight && this.opts.highlight == as.location_id
				"highlight" : view_loc_id && view_loc_id == as.location_id
			    };
		    }
		}
	    }
	}
    }

    if (opt.with_rack_link) {
	var $extra = $("<tr class='rack_row extra_header'><td colspan='4' class='extra_header'><a href='#'></a></td></tr>");
	$extra.find("a").text(loc.name);
	$rack.append($extra);
	$extra.find("a").click(function () {
	    this.view($("#bottom_panel"));
	    return false;
	}.bind(L));
    }
    $rack.append("<tr class='rack_row header'>" +
		 "<td class='rackpos_num header'>&nbsp;</td>" +
		 "<td class='rackpos front header'>Front</td>" +
		 "<td class='rackpos interior header'>Interior</td>" +
		 "<td class='rackpos back header'>Back</span>" +
		 "</tr>");
    for (var i = 1; i <= L.rack_size; i++) {
	var n = L.rack_downwards ? i : L.rack_size - i + 1;
	var $row = $("<tr class='rack_row'>" +
		     "<td class='rackpos_num'></td>");
	for (var fib in FIBS) {
	    var oc = occupied[n] ? occupied[n][fib] : 0;
	    if (oc) {
		if (!assets[oc.as].handled) {
		    var $col = $("<td class='rackpos'>&nbsp;</td>");
		    $col.addClass(FIBS[fib]);
		    $col.addClass("occupied");
		    if (oc.highlight)
			$col.addClass("highlighted");
		    $col.attr("colspan", oc.colspan);
		    $col.attr("rowspan", oc.rowspan);
		    $row.append($col);
		    assets[oc.as].handled = true;
		    (function (){
			var url = netdot_path +
			    "management/view.html?showheader=0&table=Asset&dowindow=1&id=" +
			    oc.as;
			$col.text("");
			$col.append("<a href='#'></a>");
			$col.find("a").text(assets[oc.as].label);
			$col.find("a").attr("title", assets[oc.as].label);
			$col.find("a").click(function () {
			    openwindow(url);
			    return false;
		 	});
		    }());
		}
	    } else {
		var $col = $("<td class='rackpos'>&nbsp;</td>");

		if (!opt.disable_rack_select && select_id && select_vsize && select_hsize && fib != FIB_INTERIOR) {
		    var general_ok = 1;
		    var fib_possibilities;
		    if (select_hsize == 1) {
			fib_possibilities = [[FIB_FRONT], [FIB_BACK]];
		    } else if (select_hsize == 2) {
			fib_possibilities = [[FIB_FRONT,FIB_INTERIOR], [FIB_BACK,FIB_INTERIOR]];
		    } else {
			fib_possibilities = [[FIB_FRONT, FIB_BACK, FIB_INTERIOR]];
			if (fib == FIB_BACK) general_ok = 0;
		    }
		    var ok = 1;
		    for (var f = 0; f < fib_possibilities.length; f++) {
			ok = 1;
			var possible_fibs = fib_possibilities[f];
			for (var g = 0; g < possible_fibs.length; g++) {
			    var fib_test = possible_fibs[g];
			    if (L.rack_downwards) {
				for (var k = 0; k < select_vsize; k++) {
				    if (n-k <= 0) {
					ok = 0;
				    } else if (occupied[n-k] && occupied[n-k][fib_test]) {
					if (!occupied[n-k][fib_test].highlight)
					    ok = 0;
				    }
				}
			    } else {
				for (var k = 0; k < select_vsize; k++) {
				    if (n+k > L.rack_size) {
					ok = 0;
				    } else if (occupied[n+k] && occupied[n+k][fib_test]) {
					if (!occupied[n+k][fib_test].highlight)
					    ok = 0;
				    }
				}
			    }
			}
		    }
		    if (general_ok && ok) {
			var pid;
			if (fib == FIB_FRONT)
			    pid = loc.front_positions[n];
			else
			    pid = loc.back_positions[n];
			var $radio = $("<input type='radio' name='rackpos'></input>");
			$radio.val(pid);
			$col.append($radio);
		    }
		}

		$col.addClass(FIBS[fib]);
		$row.append($col);
	    }
	}
	$row.find(".rackpos_num").text(n);
	$rack.append($row);
    }

    return $rack_table;
};

Location.prototype.edit = function ($div) {
    var $title     = $div.find(".containerheadleft");
    var $menu      = $div.find(".containerheadright");
    var $container = $div.find(".containerbody");

    $title.text("Location edit");

    $menu.empty();
    $menu.append("<input class='cancel btn' type='button' value='cancel'/>");
    $menu.find(".cancel").click(function () {
	this.view($div);
	return false;
    }.bind(this));
    $menu.append("&nbsp;");
    $menu.append("<input class='submit btn' type='submit' value='submit'/>");
    var $form_submit = function () {
	this.loc.name = this.name_field.val();
	this.loc.info = this.info_field.val();
	var o = this.loc.options;
	var seen = {};
	for (var i = 0; i < o.length; i++) {
	    o[i].value = this.fields[o[i].option_spec_id].val();
	    seen[o[i].option_spec_id] = true;
	}
	for (var i in this.los) {
	    if (seen[i]) continue;
	    var val = this.fields[i].val();
	    if (val != "")
		o[o.length] = {
		    "option_spec_id": i,
		    "value": val
		};
	}
	remote_post(this.loc, function (r) {
	    locs[r.id] = this.loc = r;
	    this.view($div);
	}.bind(this));
	return false;
    }.bind(this);
    $menu.find(".submit").click($form_submit);

    $container.empty();
    var $tab = $("<div class='location_edit'></div>");
    var $type = $("<div class='vtf'>" +
	"<span class='vtf_descr'></span>" +
	"<span class='vtf_val'></span>" +
	"</div>");
    $type.find(".vtf_descr").text("Location type");
    $type.find(".vtf_val").text(this.loc.location_type.name);
    $tab.append($type);

    this.name_field = new EditTextField("Location name", this.loc.name);
    $tab.append(this.name_field.obj());

    this.info_field = new EditTextArea("Location info", this.loc.info);
    $tab.append(this.info_field.obj());

    this.fields = {};
    for (var i in this.los) {
	this.fields[i] = this.los[i].edit();
    }
    var o = this.loc.options;
    for (var i = 0; i < o.length; i++) {
	this.fields[o[i].option_spec_id].val(o[i].value);
    }

    for (var i in this.fields) {
	$tab.append(this.fields[i].obj());
    }

    $container.append($tab);

    $div.show();
};

Location.prototype.reset_create_fields = function () {
    var lot = this.name2lot[this.lot_field.val()];

    for (var i in this.fields) {
	this.fields[i].obj().remove();
    }
    this.fields = {};

    for (var i in LOS) {
	if (LOS[i] && LOS[i].location_type == lot.id) {
	    this.fields[LOS[i].id] = LOS[i].edit();
	}
    }
    for (var i in this.fields) {
	this.$tab.append(this.fields[i].obj());
    }
};

Location.prototype.create = function ($div) {
    var $title     = $div.find(".containerheadleft");
    var $menu      = $div.find(".containerheadright");
    var $container = $div.find(".containerbody");

    $title.text("Creating new location");

    $menu.empty();
    $menu.append("<input class='cancel btn' type='button' value='cancel'/>");
    $menu.find(".cancel").click(function () {
	this.view($div);
	return false;
    }.bind(this));
    $menu.append("&nbsp;");
    $menu.append("<input class='submit btn' type='submit' value='submit'/>");
    $menu.find(".submit").click(function () {
	var lot = this.name2lot[this.lot_field.val()];
	var loc = {
	    "location_type" : lot.id, /* just use the id */
	    "name"          : this.name_field.val(),
	    "info"          : this.info_field.val(),
	    "located_in"    : this.loc.id ? this.loc.id : null
	};
	var o = [];
	for (var i in LOS) {
	    if (LOS[i] && LOS[i].location_type == lot.id) {
		var val = this.fields[LOS[i].id].val();
		if (val != "")
		    o[o.length] = {
			"option_spec_id": LOS[i].id,
			"value": val
		    };
	    }
	}
	loc.options = o;
	remote_post(loc, function (r) {
	    locs[r.id] = r;
	    // XXX need to reload SELF due to the new child;  also reset tree thing
	    this.view($div);
	}.bind(this));
	return false;
    }.bind(this));

    $container.empty();
    this.$tab = $("<div class='location_create'></div>");

    var lots = [];
    this.name2lot = {};
    for (var i = 0; i < LOT.length; i++) {
	if ((LOT[i].magic & MAGIC_HIDDEN) == 0) {
	    lots[lots.length] = LOT[i].name;
	    this.name2lot[LOT[i].name] = LOT[i];
	}
    }
    var def_lot = lots[0];
    this.lot_field = new EditSelectField("Location type", lots, def_lot);
    this.$tab.append(this.lot_field.obj());
    this.name_field = new EditTextField("Location name", "");
    this.$tab.append(this.name_field.obj());
    this.info_field = new EditTextArea("Location info", "");
    this.$tab.append(this.info_field.obj());
    this.fields = {};
    this.reset_create_fields();
    this.lot_field.obj().find("select").change(function () {
	this.reset_create_fields();
	return false;
    }.bind(this));

    $container.append(this.$tab);

    $div.show();
};

var ViewTextField = function (descr, value) {
	this.descr = descr;
	this.value = value;
	this.$object = $("<div class='vtf'>" +
		"<span class='vtf_descr'></span>" +
		"<span class='vtf_val'></span>" +
		"</div>");
	this.$object.find(".vtf_descr").text(descr);
	if (value) {
		this.$object.find(".vtf_val").text(value);
	}
};

ViewTextField.prototype.val = function (value) {
	if (value != null) {
		this.value = value;
		this.$object.find(".vtf_val").text(value);
	}
	return this.value;
};

ViewTextField.prototype.obj = function (val) {
	return this.$object;
};

var EditTextField = function (descr, value) {
	this.descr = descr;
	this.value = value;
	this.$object = $("<div class='etf'>" +
		"<span class='etf_descr'></span>" +
		"<span class='etf_val'>" +
		"<input type='text' value='' />" +
		"</span>" +
		"</div>");
	this.$object.find(".etf_descr").text(descr);
	if (value) {
	    this.$object.find(".etf_val").find("input").val(value);
	}
};

EditTextField.prototype.val = function (value) {
    if (value != null) {
	this.value = value;
	this.$object.find(".etf_val").find("input").val(value);
    }
    this.value = this.$object.find(".etf_val").find("input").val();
    return this.value;
};

EditTextField.prototype.obj = function (val) {
	return this.$object;
};

var EditTextArea = function (descr, value) {
	this.descr = descr;
	this.value = value;
	this.$object = $("<div class='etf'>" +
		"<span class='etf_descr'></span>" +
		"<span class='etf_val'>" +
		"<textarea rows='4' cols='50'></textarea>" +
		"</span>" +
		"</div>");
	this.$object.find(".etf_descr").text(descr);
	if (value) {
	    this.$object.find(".etf_val").find("textarea").val(value);
	}
};

EditTextArea.prototype.val = function (value) {
    if (value != null) {
	this.value = value;
	this.$object.find(".etf_val").find("textarea").val(value);
    }
    this.value = this.$object.find(".etf_val").find("textarea").val();
    return this.value;
};

EditTextArea.prototype.obj = function (val) {
	return this.$object;
};

var EditSelectField = function (descr, sel, value) {
	this.descr = descr;
	this.sel = sel;
	this.value = value;
	this.$object = $("<div class='etf'>" +
		"<span class='etf_descr'></span>" +
		"<span class='etf_val'>" +
		"<select class='esf'></select>" +
		"</span>" +
		"</div>");
	this.$object.find(".etf_descr").text(descr);
	var $select = this.$object.find(".etf_val").find("select");
	for (var i = 0; i < sel.length; i++) {
	    var s = sel[i];
	    var $opt = $("<option value=''></option>");
	    $opt.attr("value", s);  $opt.text(s);
	    $select.append($opt);
	}
	if (value) {
	    $select.val(value);
	}
};

EditSelectField.prototype.val = function (value) {
    if (value != null) {
	this.value = value;
	this.$object.find(".etf_val").find("select").val(value);
    }
    this.value = this.$object.find(".etf_val").find("select").val();
    return this.value;
};

EditSelectField.prototype.obj = function (val) {
	return this.$object;
};
