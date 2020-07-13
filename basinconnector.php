<?php
/*

Basin Connector

Copyright (c) 2020 Christopher B. Pond

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/

//Takes basins and optimally connects them into single tree so that there is minimal back-tracking.
//This version ranks basin connexions by backtrack descent channel distance, exclusive of boundary-to-boundary transitions, then to rank by descent channel including boundaries,
//then by island area, and then by interface length descending.  This should, in theory, be deterministic.
//For each unique basin-to-basin pairing a single, optimal watershed connexion point is established.
//Future development: Use altitude at basin boundary to rank connexions.

//Requires wdws, wdwsconnections, wdwsislandconnections.  Updates wdws.basinid. Generates wdwstree.
require ("include.php");

//This could take a while...
set_time_limit (100000);

?><html><head><title>Basin Connector <?php echo (VERSION);?></title></head><body>
<h2>Basin Connector <?php echo (VERSION);?></h2>
Optimising basin connections...<br><?php
flush();

//Simple grouping recursion.  Set basinid for watersheds.
function setwatershedbasin($wsid, $basinid, &$trees) {
	$trees[$wsid]["basinid"] = $basinid;
	foreach ($trees[$wsid]["children"] as $childid) {
		setwatershedbasin($childid, $basinid, $trees);
	}
}

//This will make the first watershed a child of the second. If the child already has a parent, it will switch the relationship and trace back until it finds the root.
function connectwatersheds($childwsid, $parentwsid, &$trees) {
	if ($trees[$childwsid]["parentid"] !== null) {
		connectwatersheds($trees[$childwsid]["parentid"], $childwsid, $trees);
	}
	//Set parent
	$trees[$childwsid]["parentid"] = $parentwsid;
	//Add to children
	array_push ($trees[$parentwsid]["children"], $childwsid);
	//Remove parent from child's children
	$trees[$childwsid]["children"] = array_diff($trees[$childwsid]["children"], array($parentwsid));
	$trees[$childwsid]["children"] = array_values($trees[$childwsid]["children"]);
}

//Set basin root.  Works on basins, not watersheds.
function setbasinroot($basinid, $rootbasinid, &$basins) {
	$basins[$basinid]["rootbasinid"] = $rootbasinid;
	foreach ($basins[$basinid]["childbasinids"] as $childbasinid) {
		setbasinroot($childbasinid, $rootbasinid, $basins);
	}
}

//This will make the first basin a child of the second. If the child already has a parent, it will switch the relationship and trace back until it finds the root.
function connectbasins($childbasinid, $parentbasinid, &$basins) {
	if ($basins[$childbasinid]["parentbasinid"] !== null) {
		connectbasins($basins[$childbasinid]["parentbasinid"], $childbasinid, $basins);
	}
	//Set parent
	$basins[$childbasinid]["parentbasinid"] = $parentbasinid;
	//Add to children
	array_push ($basins[$parentbasinid]["childbasinids"], $childbasinid);
	//Remove parent from child's children
	$basins[$childbasinid]["childbasinids"] = array_diff($basins[$childbasinid]["childbasinids"], array($parentbasinid));
	$basins[$childbasinid]["childbasinids"] = array_values($basins[$childbasinid]["childbasinids"]);
}

//This will return the length of the interface between ws0 and ws1.  This should be identical either way.
function getinterfacelength($wsid0, $wsid1, &$trees) {
	$wsnumber = array_search($wsid1, $trees[$wsid0]["neighborwsids"]);
	if ($wsnumber === false) {
		return(0);
	} else {
		return($trees[$wsid0]["neighborlengths"][$wsnumber]);
	}
}

//This returns an array containing items to compare to rank connexions.
function getconnectionscore($basinid0, $basinid1, &$basins, &$trees, &$islands) {
	$basinnumber1 = array_search($basinid1, $basins[$basinid0]["basinids1"]);
	$connectionscore = array();
	$connectionscore["descentdistance"] = $basins[$basinid0]["descentdistances"][$basinnumber1];
	$connectionscore["boundarydescentdistance"] = $basins[$basinid0]["boundarydescentdistances"][$basinnumber1];
	$connectionscore["thearea"] = $islands[$trees[$basinid0]["islandid"]]["thearea"];
	$connectionscore["thelength"] = getinterfacelength($basins[$basinid0]["wsids0"][$basinnumber1], $basins[$basinid0]["wsids1"][$basinnumber1], $trees);
	return ($connectionscore);
}

//Comparison function for basins.  First goes by ascending distance, then by descending interface length.
function comparebasinconnections($a, $b) {
	//If the reversal of the descent channel beyond the boundary is less, the connexion is always a better fit.
	if ($a["descentdistance"] - $a["boundarydescentdistance"] < $b["descentdistance"] - $b["boundarydescentdistance"]) {
		return(-1);
	} elseif ($a["descentdistance"] - $a["boundarydescentdistance"] > $b["descentdistance"] - $b["boundarydescentdistance"]) {
		return(1);
	} else {
		//They should only ever be precisely equal if they are both on the boundary, so the next step is to look at the total distance.
		if ($a["descentdistance"] < $b["descentdistance"]) {
			return(-1);
		} elseif ($a["descentdistance"] > $b["descentdistance"]) {
			return(1);
		} else {
			//The last possibility is if all values are zero.  This can happen if there is a root-to-root connexion between islands.  In this case, rank by island area.
			if ($a["thearea"] < $b["thearea"]) {
				return(-1);
			} elseif ($a["thearea"] > $b["thearea"]) {
				return(1);
			} else {
				//The very last method to distinguish between two connexions is by the length of the border they have in common.
				if ($a["thelength"] > $b["thelength"]) {
					return(-1);
				} elseif ($a["thelength"] < $b["thelength"]) {
					return(1);
				} else {
					//This may happen in a sort where a connexion closer to the root is reset by a more expensive connexion higher up.
					return(0);
				}
			}
		}
	}
}

////////
//MAIN//
////////

//Initialise trees.
$trees = array();
//Initialise basins.
$basins = array();
//Initialise islands.
$islands = array();

//Recursive function calls apparently don't work with PGScript!  This should more properly be included with the initial data cleanup.
$currentdb->execute("
	--Once ParentID is set, BasinIDs can be set with a simple recursive call now.
	with recursive ws(id, parentid, basinid, path) as (
		select id, parentid, id, array[id] from wdws where parentid is null
	union all
		select b.id, b.parentid, a.basinid, a.path || b.id from ws a inner join wdws b on a.id = b.parentid where not b.id = any(a.path)
	) update wdws a set basinid = b.basinid from ws b where a.id = b.id;
");

//Grab island areas.
$rs = $currentdb->execute("select islandid, sum(st_area(st_transform(mercgeom, 4326)::geography)) as thearea from wdws group by 1 order by 1;");
while ($row = pg_fetch_array($rs)) {
	$islands[$row["islandid"]]["thearea"] = (double)$row["thearea"];
}

//Initialise tree items and basin items.
$rs = $currentdb->execute("select parentid, id as wsid, basinid, islandid, boundary from wdws order by id;");
while ($row = pg_fetch_array($rs)) {
	if ($row["boundary"] === "t") {
		$trees[$row["wsid"]]["boundary"] = true;
	} else {
		$trees[$row["wsid"]]["boundary"] = false;
	}
	$trees[$row["wsid"]]["basinid"] = (int)$row["basinid"];
	$trees[$row["wsid"]]["islandid"] = (int)$row["islandid"];
	$trees[$row["wsid"]]["parentid"] = NULL;
	$trees[$row["wsid"]]["children"] = array();
	$trees[$row["wsid"]]["neighborwsids"] = array();
	$trees[$row["wsid"]]["neighborlengths"] = array();
	$trees[$row["wsid"]]["neighborexitpointdistances"] = array();
	$trees[$row["wsid"]]["neighboroutsidebasindistances"] = array();
	//The convention is that 0 geometries are children, and 1 geometries are parents.
	if ($row["parentid"] === NULL) {
		$basins[$row["wsid"]]["rootbasinid"] = (int)$row["wsid"];
		$basins[$row["wsid"]]["parentbasinid"] = null;
		$basins[$row["wsid"]]["childbasinids"] = array();
		$basins[$row["wsid"]]["basinids1"] = array();
		$basins[$row["wsid"]]["wsids0"] = array();
		$basins[$row["wsid"]]["wsids1"] = array();
		$basins[$row["wsid"]]["descentdistances"] = array();
		$basins[$row["wsid"]]["boundarydescentdistances"] = array();
	}
}

//Add connexion between parent and children.
$rs = $currentdb->execute("select parentid, id as wsid from wdws order by id;");
while ($row = pg_fetch_array($rs)) {
	if ($row["parentid"] !== NULL) {
		$trees[$row["wsid"]]["parentid"] = (int)$row["parentid"];
		array_push ($trees[$row["parentid"]]["children"], (int)$row["wsid"]);
	}
}

//Set connection data.
$rs = $currentdb->execute("
	--This should return a sum total of boundary length and exit point distance for each neighbour pair.  Islands return zero.  
	--Where the connexion links two basins, the great circle closest approach from exit point to boundary is returned.
	drop table if exists _connections; select a.*, st_distance(st_transform(b.exitmercgeom, 4326)::geography, st_transform(c.exitmercgeom, 4326)::geography) as exitpointdistance
	into temp _connections from (select wsid0, wsid1, sum(st_length(mercgeom)) as thelength from wdwsconnections where wsid0 < wsid1 group by 1,2) a inner join wdws b on a.wsid0 = b.id inner join wdws c on a.wsid1 = c.id
	union select wsid0, wsid1, 0, 0 from wdwsislandconnections where wsid0 < wsid1;
	--Reciprocal will generate different distances.  This should result in a unique score for all but island connexions.  This should be scored by child island area.
	select a.*, case when b.basinid = c.basinid then 0 else st_distance(st_transform(b.exitmercgeom, 4326)::geography, st_transform(c.mercgeom, 4326)::geography) end as outsidebasindistance from (
		select wsid0, wsid1, thelength, exitpointdistance from _connections union select wsid1, wsid0, thelength, exitpointdistance from _connections order by 1, 3 desc, 4, 2
	) a inner join wdws b on a.wsid0 = b.id inner join wdws c on a.wsid1 = c.id;
");
while ($row = pg_fetch_array($rs)) {
	array_push ($trees[$row["wsid0"]]["neighborwsids"], (int)$row["wsid1"]);
	array_push ($trees[$row["wsid0"]]["neighborlengths"], (double)$row["thelength"]);
	array_push ($trees[$row["wsid0"]]["neighborexitpointdistances"], (double)$row["exitpointdistance"]);
	//This one is only greater than zero when the neighbour is in another basin.
	array_push ($trees[$row["wsid0"]]["neighboroutsidebasindistances"], (double)$row["outsidebasindistance"]);
}

//Cycle through each pair of adjacent watersheds, looking for shortest connexion point for each basin.
foreach ($trees as $wsid0 => $value) {
	$basinid0 = $value["basinid"];
	foreach ($value["neighborwsids"] as $wsid1) {
		if ($trees[$wsid1]["basinid"] !== $basinid0) {
			$basinid1 = $trees[$wsid1]["basinid"];
			$basinnumber1 = array_search($basinid1, $basins[$basinid0]["basinids1"]);
			if ($basinnumber1 !== false) {
				$existingconnectionscore = getconnectionscore($basinid0, $basinid1, $basins, $trees, $islands);
			} else {
				$existingconnectionscore = null;
			}
			$newconnectionscore = array();
			$newconnectionscore["descentdistance"] = 0;
			$newconnectionscore["boundarydescentdistance"] = 0;
			//This is essentially always going to be identical, because there should only ever be one way to get from one island to another... It's only needed to be conformant with the comparison function.
			$newconnectionscore["thearea"] = $islands[$trees[$wsid0]["islandid"]]["thearea"];
			$newconnectionscore["thelength"] = getinterfacelength($wsid0, $wsid1, $trees);
			$currentwsid = $wsid0;
			//The initial watershed must add the distance from the exit point to the border.
			$neighbornumber = array_search($wsid1, $trees[$currentwsid]["neighborwsids"]);
			if ($neighbornumber !== false) {
				//Add the distance to the basin border to the total descent distance.
				$newconnectionscore["descentdistance"] += $trees[$currentwsid]["neighboroutsidebasindistances"][$neighbornumber];
				if ($trees[$currentwsid]["boundary"] && $trees[$wsid1]["boundary"]) {
					//If both watersheds are on the boundary, add the distance to the border to the boundary descent.
					$newconnectionscore["boundarydescentdistance"] += $trees[$currentwsid]["neighboroutsidebasindistances"][$neighbornumber];
				}
			}
			//Descend tree to root.  Stop if the existing connexion is a better fit.
			while ($trees[$currentwsid]["parentid"] !== null && ($existingconnectionscore === null || comparebasinconnections($newconnectionscore, $existingconnectionscore) < 0)) {
				$neighbornumber = array_search($trees[$currentwsid]["parentid"], $trees[$currentwsid]["neighborwsids"]);
				//For each watershed, add the distance between exit points.
				if ($neighbornumber !== false) {
					$newconnectionscore["descentdistance"] += $trees[$currentwsid]["neighborexitpointdistances"][$neighbornumber];
					if ($trees[$currentwsid]["boundary"] && $trees[$wsid1]["boundary"]) {
						//If both watersheds are on the boundary, add the exit point distance to the boundary descent.
						$newconnectionscore["boundarydescentdistance"] += $trees[$currentwsid]["neighborexitpointdistances"][$neighbornumber];
					}
					
				}
				$currentwsid = $trees[$currentwsid]["parentid"];
			}
			//If the basin to basin connection is new, add it.
			if ($basinnumber1 === false) {
				array_push ($basins[$basinid0]["basinids1"], $basinid1);
				array_push ($basins[$basinid0]["wsids0"], $wsid0);
				array_push ($basins[$basinid0]["wsids1"], $wsid1);
				array_push ($basins[$basinid0]["descentdistances"], $newconnectionscore["descentdistance"]);
				array_push ($basins[$basinid0]["boundarydescentdistances"], $newconnectionscore["boundarydescentdistance"]);
			//There should never be an equivalence, but if there is, it will retain whichever connexion was first set.
			} elseif (comparebasinconnections($newconnectionscore, $existingconnectionscore) < 0) {
				$basins[$basinid0]["basinids1"][$basinnumber1] = $basinid1;
				$basins[$basinid0]["wsids0"][$basinnumber1] = $wsid0;
				$basins[$basinid0]["wsids1"][$basinnumber1] = $wsid1;
				$basins[$basinid0]["descentdistances"][$basinnumber1] = $newconnectionscore["descentdistance"];
				$basins[$basinid0]["boundarydescentdistances"][$basinnumber1] = $newconnectionscore["boundarydescentdistance"];
			}
		}
	}
}

//This gets sorted.
$basinconnections = array();
foreach ($basins as $basinid0 => $value) {
	foreach ($value["basinids1"] as $basinnumber1 => $basinid1) {
		array_push ($basinconnections, array("basinid0" => $basinid0, "basinid1" => $basinid1, "descentdistance" => $value["descentdistances"][$basinnumber1],
			"boundarydescentdistance" => $value["boundarydescentdistances"][$basinnumber1], "thearea" => $islands[$trees[$basinid0]["islandid"]]["thearea"],
			"thelength" => getinterfacelength($value["wsids0"][$basinnumber1], $value["wsids1"][$basinnumber1], $trees)));
	}
}
//Sort basin connections.
usort($basinconnections, "comparebasinconnections");

//Start with first connector, and find out if reversing the entire child tree really matches the score in the ranking list.  If it does, mark it and continue, if it doesn't, set the new values and reorder.
//Report total connexions to process.
echo (count($basinconnections)." total connections to process.<BR>"); flush();
$n = 0;
while ($n < count($basinconnections)) {
	$basinid0 = $basinconnections[$n]["basinid0"];
	$basinid1 = $basinconnections[$n]["basinid1"];
	//If they already have the same root, skip processing.
	if ($basins[$basinid0]["rootbasinid"] === $basins[$basinid1]["rootbasinid"]) {
		$n++;
	} else {
		$highestconnectionscore = null;
		//Walk back to root of tree to be connected to find maximum distance penalty in tree reversal.
		while ($basinid0 !== null) {
			$currentconnectionscore = getconnectionscore($basinid0, $basinid1, $basins, $trees, $islands);
			if ($highestconnectionscore === null || comparebasinconnections($highestconnectionscore, $currentconnectionscore) < 0) {
				$highestconnectionscore = $currentconnectionscore;
			}
			$basinid1 = $basinid0;
			$basinid0 = $basins[$basinid0]["parentbasinid"];
		}
		//If the maximum penalty is larger than the previously calculated penalty, reset the penalty in the array and reorder it, starting from zero.
		if (comparebasinconnections($basinconnections[$n], $highestconnectionscore) < 0 ) {
			//Save current score before resetting, in order to rewind to just prior.  This should avoid problems with equivalent values and indeterminate sorts. 
			$previousconnectionscore = $basinconnections[$n];
			//Give progress report
			echo ("Re-sort at ".$n."<BR>"); flush();
			$basinconnections[$n]["descentdistance"] = $highestconnectionscore["descentdistance"];
			$basinconnections[$n]["boundarydescentdistance"] = $highestconnectionscore["boundarydescentdistance"];
			$basinconnections[$n]["thearea"] = $highestconnectionscore["thearea"];
			$basinconnections[$n]["thelength"] = $highestconnectionscore["thelength"];
			usort($basinconnections, "comparebasinconnections");
			//Back up until a higher-scoring match is found or until the counter hits zero.  This should allow duplicate matches to function correctly.
			while ($n > 0 && comparebasinconnections($basinconnections[$n], $previousconnectionscore) >= 0) {
				$n--;
			}
		} else {
			//If the combined traceback penalty is less than or equal to the current connection penalty, connect the basins.
			//The BasinIDs have been scrambled walking back to the root, so values must be pulled from array.
			connectbasins($basinconnections[$n]["basinid0"], $basinconnections[$n]["basinid1"], $basins);
			setbasinroot($basinconnections[$n]["basinid0"], $basins[$basinconnections[$n]["basinid1"]]["rootbasinid"], $basins);
		}
	}
}

//Copy changes to watershed tree.
foreach ($basins as $basinid0 => $value) {
	if ($value["parentbasinid"] !== null) {
		$basinnumber1 = array_search($value["parentbasinid"], $basins[$basinid0]["basinids1"]);
		$wsid0 = $basins[$basinid0]["wsids0"][$basinnumber1];
		$wsid1 = $basins[$basinid0]["wsids1"][$basinnumber1];
		connectwatersheds($wsid0, $wsid1, $trees);
		setwatershedbasin($wsid0, $basins[$basinid0]["rootbasinid"], $trees);
	}
}

//Write to external table.
$copyout = array();
foreach ($trees as $wsid => $value) {
	$copyout[] = $wsid."\t".($value["parentid"] ?? "\\N")."\t".$value["basinid"];
}
pg_query($currentdb->connection, "drop table if exists _fullwstree; create temp table _fullwstree (wsid int, parentid int, basinid int);");
pg_copy_from($currentdb->connection, "_fullwstree", $copyout);
$currentdb->execute(
	"drop table if exists wdwstree; select b.id, b.externalid, a.parentid, b.stateid, b.basinid, b.islandid, b.boundary, b.population, st_centroid(b.mercgeom) as centerpoint, b.mercgeom
	into wdwstree from _fullwstree a inner join wdws b on a.wsid = b.id order by b.id;"
);

?>Done!
</body></html>
