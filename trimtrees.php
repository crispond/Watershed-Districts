<?php

/*

Trim Trees

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

require ("include.php");
//Trim Trees algorithm defines contiguous territory of roughly equivalent population created directly from census blocks.
//Requires wdws, wdwstree, wdwsconnections, wdcensusstates, wdcensusblocks, wdcensusblockislandconnections, wdcensusblockconnections, wdcensusws

//This could take a while...
set_time_limit (100000);
//...and require a lot of memory...
ini_set('memory_limit', '16G');
define("TAU", pi() * 2.0);

?><!DOCTYPE html><html><head><title>Trim Trees <?php echo (VERSION);?></title>
<script type = "text/javascript">
function initialize() {
	if (document.theform) if (document.theform.state) {
		document.theform.state.focus();
	}
}
</script></head><body onload = "initialize();">
<h2>Trim Trees <?php echo (VERSION);?></h2><?php
flush();

/////////////
//FUNCTIONS//
/////////////

//Simple swap function.
function swap(&$x, &$y) {
	$tmp = $x;
	$x = $y;
	$y = $tmp;
}

//Get the the distance between two points.  This should be replaced with proper great circle measurement.
function getdistance(&$p0, &$p1) {
	//Do a sanity check, JIC.
	if (array_key_exists("x", $p0) && array_key_exists("x", $p1) && array_key_exists("y", $p0) && array_key_exists("y", $p1)) {
		return (sqrt(($p0["x"] - $p1["x"]) ** 2 + ($p0["y"] - $p1["y"]) ** 2));
	} else {
		return(null);
	}
}

//Get radian distance between two vectors.
function getangledistance(&$v0, &$v1) {
	if (($v0["dx"] === 0.0 && $v0["dy"] === 0.0) || ($v1["dx"] === 0.0 && $v1["dy"] === 0.0)) {
		$dtheta = null;
	} else {
		$dtheta = atan2($v1["dy"], $v1["dx"]) - atan2($v0["dy"], $v0["dx"]);
		if (array_key_exists("sign", $v0)) {
			//If initial vector contains a sign direction, use that, otherwise calculate closest distance backward or forward.
			if ($v0["sign"] < 0 && $dtheta > 0) {
				$dtheta = $dtheta - TAU;
			} elseif ($v0["sign"] > 0 && $dtheta < 0) {
				$dtheta = $dtheta + TAU;
			}
		} else {
			//Find closest direction.
			if ($dtheta > pi()) {
				$dtheta = $dtheta - TAU;
			} elseif ($dtheta < -pi()) {
				$dtheta = $dtheta + TAU;
			}
		}
	}
	return($dtheta);
}

//Along the line defined by vector, distance from point to perpendicular intersection of line and supplied point.  This may also be converted to great circle measurement.
function getperpendiculardistance(&$p, &$v) {
	if ($p["x"] === null || $p["y"] === null || $v["x"] === null || $v["y"] === null || $v["dx"] === null || $v["dy"] === null) {
		return (null);
	} elseif ($v["dx"] == 0 && $v["dy"] == 0) {
		//Just the distance between the points if there is no slope.  The comparison must be done with double equal, since 0 !== 0.0.
		return (sqrt(($p["x"] - $v["x"]) ** 2 + ($p["y"] - $v["y"]) ** 2));
	} else {
		$slopefactor = ($v["dx"] * ($p["x"] - $v["x"]) + $v["dy"] * ($p["y"] - $v["y"])) / ($v["dx"] ** 2 + $v["dy"] ** 2);
		if ($slopefactor < 0) {
			$sign = -1;
		} else {
			$sign = 1;
		}
		return (sqrt(($v["dx"] * $slopefactor) ** 2 + ($v["dy"] * $slopefactor) ** 2) * $sign);
	}
}

//Given an edge defined by a vector, $v, calculate score of supplied point.  A sign field indicates points should be calculated by angle using point in vector as the pivot.
//The vector is defined by a perpendicular slope to a target, not by the slope of the edge itself.
function getedgescore(&$p, &$v) {
	$score = null;
	if (array_key_exists("sign", $v)) {
		//The edge has a pivot.  Set point vector.
		$v1["dx"] = $p["x"] - $v["x"];
		$v1["dy"] = $p["y"] - $v["y"];
		//This makes sure all numbers behind edge are negative, from -TAU/2 to 0.  Using supplied vector means we don't have to set a sign for the point vector.
		$score = $v["sign"] * getangledistance($v, $v1) - 3 / 4 * TAU;
		if ($score < -TAU / 2) {
			$score = $score + TAU;
		}
	} else {
		//The edge just descends straight down.
		$score = getperpendiculardistance($p, $v);
	}
	return($score);
}

//Return the length of an edge.  Uses all district blocks adjacent to any prospect.
//Future development:  When edge is not contiguous, do not count length of natural obstacle.
function getedgelength($v, $edgeblocks, &$censusblocks) {
	$edgelength = null;
	if (count($edgeblocks) > 0) {
		//Locate most extreme block in edge.
		if (array_key_exists("sign", $v)) {
			//If there's a pivot point, $block0id will be farthest point from pivot.
			foreach (array_keys($edgeblocks) as $blockid) {
				$edgeblocks[$blockid] = getdistance($censusblocks[$blockid], $v);
			}
		} else {
			//If no pivot is supplied, use perpendicular of slope to score edge like a ruler.
			swap($v["dx"], $v["dy"]);
			$v["dx"] = -$v["dx"];
			foreach (array_keys($edgeblocks) as $blockid) {
				$edgeblocks[$blockid] = getperpendiculardistance($censusblocks[$blockid], $v);
			}
		
		}
		//A non-pivoting edge may choose either maximum or minimum value, but a pivot must choose maximum.
		arsort($edgeblocks);
		reset($edgeblocks);
		$block0id = key($edgeblocks);
		//Given $block0, find $block1.
		foreach (array_keys($edgeblocks) as $blockid) {
			$edgeblocks[$blockid] = getdistance($censusblocks[$block0id], $censusblocks[$blockid]);
		}
		arsort($edgeblocks);
		reset($edgeblocks);
		$edgelength = current($edgeblocks);
	}
	return ($edgelength);
}

//Recurring through branches to calculate cumulative population.
function populatebranches($wsid, &$trees) {
	$wspopulation = 0;
	if (!$trees[$wsid]["closed"]) {
		$wspopulation = $trees[$wsid]["population"];
		foreach ($trees[$wsid]["children"] as $childid) {
			$wspopulation += populatebranches($childid, $trees);
		}
		$trees[$wsid]["branchpopulation"] = $wspopulation;
	}
	return($wspopulation);
}

//Recur through branch, finding farthest point from branch root.  Only considers contiguous boundary path.  Will not return value for watershed which does not overlap target block group.
function getfarthestboundaryws($wsid, &$groupwatersheds, &$trees) {
	$farthestboundarywsid = null;
	if (!$trees[$wsid]["closed"] && $trees[$wsid]["boundary"]) {
		//If watershed overlaps block group, it can be considered.
		if (array_key_exists($wsid, $groupwatersheds)) {
			$farthestboundarywsid = $wsid;
		}
		foreach ($trees[$wsid]["children"] as $childid) {
			$farthestchildboundarywsid = getfarthestboundaryws($childid, $groupwatersheds, $trees);
			if ($farthestboundarywsid === null || (
				$farthestchildboundarywsid !== null && $groupwatersheds[$farthestchildboundarywsid] >  $groupwatersheds[$farthestboundarywsid]
			)) {
				$farthestboundarywsid = $farthestchildboundarywsid;
			}
		}
	}
	return ($farthestboundarywsid);
}

//If a block group contains a block, return true, else return false.
function groupscontainblock($blockid, &$censusblockgroups) {
	foreach (array_keys($censusblockgroups) as $groupid) {
		if (array_key_exists($blockid, $censusblockgroups[$groupid]["blocks"])) {
			return(true);
		}
	}
	return(false);
}

//Travel through connected blocks, adding each one found to supplied census block group.
function addblockstogroup($blockid, $branchrootwsid, $districtid, &$censusblockgroup, &$censusblocks, &$trees) {
	//It may be a boundary block.
	if ($censusblocks[$blockid]["districtid"] !== $districtid || (
		$branchrootwsid !== null && $trees[$censusblocks[$blockid]["wsid"]]["branchrootwsid"] !== $branchrootwsid
	)) {
		$districtindex = $censusblocks[$blockid]["districtid"];
		//Translate from null here.
		if ($districtindex === null) {
			$districtindex = 0;
		}
		if (!array_key_exists($districtindex, $censusblockgroup["neighbordistrictblocks"])) {
			$censusblockgroup["neighbordistrictblocks"][$districtindex] = array();
		}
		if (!array_key_exists($blockid, $censusblockgroup["neighbordistrictblocks"][$districtindex])) {
			$censusblockgroup["neighbordistrictblocks"][$districtindex][$blockid] = 1;
		}
	} elseif (!array_key_exists($blockid, $censusblockgroup["blocks"])) {
		$censusblockgroup["population"] += $censusblocks[$blockid]["population"];
		$censusblockgroup["blocks"][$blockid] = 1;
		//Set centroid for group: x * xarea + cx * carea / (xarea + carea) = newx
		$censusblockgroup["centroid"]["x"] = ($censusblocks[$blockid]["x"] * $censusblocks[$blockid]["thearea"] + $censusblockgroup["centroid"]["x"] * $censusblockgroup["centroid"]["thearea"])
			/ ($censusblockgroup["centroid"]["thearea"] + $censusblocks[$blockid]["thearea"]);
		$censusblockgroup["centroid"]["y"] = ($censusblocks[$blockid]["y"] * $censusblocks[$blockid]["thearea"] + $censusblockgroup["centroid"]["y"] * $censusblockgroup["centroid"]["thearea"])
			/ ($censusblockgroup["centroid"]["thearea"] + $censusblocks[$blockid]["thearea"]);
		$censusblockgroup["centroid"]["thearea"] += $censusblocks[$blockid]["thearea"];
		foreach ($censusblocks[$blockid]["connectedblockids"] as $neighborblockid) {
			addblockstogroup($neighborblockid, $branchrootwsid, $districtid, $censusblockgroup, $censusblocks, $trees);
		}
	}
}

//Travel the tree, compiling a list of censusblocks which fit the supplied criteria, track total population in each group, and record external districts and blocks for each group.
//Use zero to denote empty blocks.
function buildcensusblockgroups($wsid, $branchrootwsid, $districtid, &$censusblockgroups, &$censusblocks, &$trees) {
	if (!$trees[$wsid]["closed"] && $trees[$wsid]["branchrootwsid"] === $branchrootwsid) {
		foreach (array_keys($trees[$wsid]["blocks"]) as $blockid) {
			if (!groupscontainblock($blockid, $censusblockgroups) && $censusblocks[$blockid]["districtid"] === $districtid) {
				$censusblockgroups[] = array("population" => 0, "centroid" => array("x" => 0.0, "y" => 0.0, "thearea" => 0.0),
					"blocks" => array(), "neighbordistrictblocks" => array()
				);
				addblockstogroup($blockid, $branchrootwsid, $districtid, $censusblockgroups[count($censusblockgroups) - 1], $censusblocks, $trees);
			}
		}
		foreach ($trees[$wsid]["children"] as $childid) {
			buildcensusblockgroups($childid, $branchrootwsid, $districtid, $censusblockgroups, $censusblocks, $trees);
		}
	}
}

//For any node in the tree, mark closed as true if there are no available census blocks in either the node or any of its children.
function closewatersheds($wsid, $branchrootwsid, &$districts, &$censusblocks, &$trees) {
	if ($trees[$wsid]["closed"]) {
		$closed = true;
	} else {
		$closed = ($trees[$wsid]["openblockcount"] === 0);
		foreach ($trees[$wsid]["children"] as $childid) {
			$childclosed = closewatersheds($childid, $branchrootwsid, $districts, $censusblocks, $trees);
			//All children have to be closed as well for entire branch to be closed.
			$closed = $closed && $childclosed;
		}
		$trees[$wsid]["closed"] = $closed;
	}
	return($closed);
}

//Sets all branch root wsids for watersheds which are not not already claimed.
function setbranchrootwsid($wsid, $branchrootwsid, &$trees) {
	if (!$trees[$wsid]["closed"]) {
		$trees[$wsid]["branchrootwsid"] = $branchrootwsid;
		foreach ($trees[$wsid]["children"] as $childid) {
			setbranchrootwsid($childid, $branchrootwsid, $trees);
		}
	}
}

//Block-level district assignment.  Decrements open block count.
function setblockdistrict($blockid, $districtid, &$districts, &$censusblocks, &$trees) {
	//Try a sanity check here.
	if (!array_key_exists($blockid, $districts[$districtid]["blocks"])) {
		$districts[$districtid]["blocks"][$blockid] = 1;
		$censusblocks[$blockid]["districtid"] = $districtid;
		$districts[$districtid]["population"] += $censusblocks[$blockid]["population"];
		//x * xarea + cx * carea / (xarea + carea) = newx
		$districts[$districtid]["centroid"]["x"] = ($censusblocks[$blockid]["x"] * $censusblocks[$blockid]["thearea"] + $districts[$districtid]["centroid"]["x"] * $districts[$districtid]["centroid"]["thearea"])
			/ ($districts[$districtid]["centroid"]["thearea"] + $censusblocks[$blockid]["thearea"]);
		$districts[$districtid]["centroid"]["y"] = ($censusblocks[$blockid]["y"] * $censusblocks[$blockid]["thearea"] + $districts[$districtid]["centroid"]["y"] * $districts[$districtid]["centroid"]["thearea"])
			/ ($districts[$districtid]["centroid"]["thearea"] + $censusblocks[$blockid]["thearea"]);
		$districts[$districtid]["centroid"]["thearea"] += $censusblocks[$blockid]["thearea"];
		//Decrement block count.
		$trees[$censusblocks[$blockid]["wsid"]]["openblockcount"]--;
	}
}

//Block-level district un-assignment.  Increments open block count and reopens watershed, if closed.
function unsetblockdistrict($blockid, $districtid, &$districts, &$censusblocks, &$trees) {
	//Try a sanity check here.
	if (array_key_exists($blockid, $districts[$districtid]["blocks"])) {
		unset($districts[$districtid]["blocks"][$blockid]);
		$censusblocks[$blockid]["districtid"] = null;
		$districts[$districtid]["population"] -= $censusblocks[$blockid]["population"];
		//Reverse of above: (newx(xarea + carea) - x * xarea) / carea
		$districts[$districtid]["centroid"]["thearea"] -= $censusblocks[$blockid]["thearea"];
		$districts[$districtid]["centroid"]["x"] = ($districts[$districtid]["centroid"]["x"] * ($districts[$districtid]["centroid"]["thearea"] + $censusblocks[$blockid]["thearea"])
			- $censusblocks[$blockid]["x"] * $censusblocks[$blockid]["thearea"]
		) / $districts[$districtid]["centroid"]["thearea"];
		$districts[$districtid]["centroid"]["y"] = ($districts[$districtid]["centroid"]["y"] * ($districts[$districtid]["centroid"]["thearea"] + $censusblocks[$blockid]["thearea"])
			- $censusblocks[$blockid]["y"] * $censusblocks[$blockid]["thearea"]
		) / $districts[$districtid]["centroid"]["thearea"];
		//Increment block count.
		$trees[$censusblocks[$blockid]["wsid"]]["openblockcount"]++;
		//Open watershed again.
		$reopenwsid = $censusblocks[$blockid]["wsid"];
		while ($reopenwsid !== null && $trees[$reopenwsid]["closed"]) {
			$trees[$reopenwsid]["closed"] = false;
			$reopenwsid = $trees[$reopenwsid]["parentid"];
		}
	}
}

//Changes population by delta from wsid0 to wsid1, inclusive.
function populatedown($populatedownwsid0, $populatedownwsid1, $populationdelta, &$trees) {
	if ($populatedownwsid0 !== null) {
		$trees[$populatedownwsid0]["branchpopulation"] += $populationdelta;
		if ($populatedownwsid0 !== $populatedownwsid1) {
			populatedown($trees[$populatedownwsid0]["parentid"], $populatedownwsid1, $populationdelta, $trees);
		}
	}
}

//Recursively prune off parts of the tree which have equivalent population.
//The start point will be a branch which has sufficient population to fill an entire district where each of the children does not.
//1. Find branch root.
//2. Add stranded blocks to existing districts.
//3. For each district which has gained territory, remove blocks from edge of district to even out population.
//4. Once there are no more stranded blocks, create new district from largest contiguous group of census blocks.
function trimtrees($wsid, $districtsize, &$districts, &$censusblocks, &$trees) {
	//The root needs a bit of wiggle room.
	$lastdistrict = false;
	if ($trees[$wsid]["parentid"] === null && $trees[$wsid]["branchpopulation"] < 1.5 * $districtsize) {
		$lastdistrict = true;
	}
	//The root is either equal to, or greater than the target district size, and hasn't been assigned to a district yet.
	if (($trees[$wsid]["branchpopulation"] >= $districtsize || $lastdistrict) && !$trees[$wsid]["closed"]) {
		//Assume all child branches are smaller to start.
		$allunder = true;
		foreach ($trees[$wsid]["children"] as $childid) {
			//If a branch is found which is larger, flag $allunder as false and recur.  Do not count branches which have already been assigned to a district.
			if (!$trees[$childid]["closed"] && $trees[$childid]["branchpopulation"] > $districtsize && !$lastdistrict) {
				$allunder = false;
				trimtrees($childid, $districtsize, $districts, $censusblocks, $trees);
			}
		}
		//This is the branch root if there is enough population in it to make a district, but insufficient population in each child.
		if ($allunder) {

			//////////////////////////////
			//Fill in stranded territory//
			//////////////////////////////

			//The count of contiguous block groups which are stranded.  Null is not zero.  Cycle must complete at least once.
			$strandedgroupcount = null;
			//If there is no next district to snap blocks to or off of, the algorithm will check that there's enough space to make a district and then fill it, if so.
			$currentsnapdistrictid = null;
			//Number of blocks added and removed on last snap pass.
			//Zero blocks added means it will not try to trim the district and will also look for the next smallest district number on next pass.
			$blocksadded = null;
			//Cycle until there are no more block groups stranded.
			//To exit this loop, analysis on open space must find a single contiguous block large enough to accomodate an entire district with no stranded territory.
			//No snap district should therefore be found and no trim operation should be run.  The last pass should be the analysis finding zero stranded groups.
			while ($strandedgroupcount !== 0) {

				//1. Calculate contiguous open block groups.  If no stranded groups are found and at least one group is large enough to create a complete district, go straight to defining new district.
				//2. Find smallest district number to attach to which hasn't already been snapped.
				//3. Snap all available blocks to it.  If none are found, go to trim.  If more are found, recalculate.
				//4. Trim district.
				//5. Find next smallest district number.

				//Set main branch root.  This makes sure only open watersheds of this branch are considered.
				setbranchrootwsid($wsid, $wsid, $trees);

				//Block addition cycle.  Cycle until there are no blocks left to snap to the current district.
				while ($blocksadded !== 0) {
					//Find contiguous groups of census blocks within branch.
					$censusblockgroups = array();
					buildcensusblockgroups($wsid, $wsid, null, $censusblockgroups, $censusblocks, $trees);
					$connectedgroupcount = 0;
					$strandedgroupcount = 0;
					$largestgroupid = null;
					foreach(array_keys($censusblockgroups) as $groupid) {
						//Find largest group by population.
						if ($largestgroupid === null || $censusblockgroups[$groupid]["population"] > $censusblockgroups[$largestgroupid]["population"]) {
							$largestgroupid = $groupid;
						}
						//Check whether undefined neighbouring territory exists.
						if (array_key_exists(0, $censusblockgroups[$groupid]["neighbordistrictblocks"])) {
							//This group may be attached to some other territory later.
							$censusblockgroups[$groupid]["snaptarget"] = false;
							$connectedgroupcount++;
						} else {
							//Define the group as a snap target.  It's isolated and must be joined with some other territory.
							$censusblockgroups[$groupid]["snaptarget"] = true;
							$strandedgroupcount++;
						}
					}
					//If it cannot find any groups connected to unassigned territory, make sure the largest one by population is not a target for being snapped to another district.
					if ($connectedgroupcount === 0) {
						$censusblockgroups[$largestgroupid]["snaptarget"] = false;
						$strandedgroupcount--;
					}
					//If there is no record of the number of blocks added on the last pass, find the next largest district number beneath the current one.
					if ($blocksadded === null) {
						$nextsnapdistrictid = null;
						foreach(array_keys($censusblockgroups) as $groupid) {
							//The group must be identified as a snap target.
							if ($censusblockgroups[$groupid]["snaptarget"]) {
								//Cycle through all districts bordering group.
								foreach(array_keys($censusblockgroups[$groupid]["neighbordistrictblocks"]) as $neighbordistrictid) {
									//If district was plotted after last district, but before last prospect found, reset the prospect.
									if (($currentsnapdistrictid === null || $neighbordistrictid > $currentsnapdistrictid)
										&& ($nextsnapdistrictid === null || $nextsnapdistrictid > $neighbordistrictid)
									) {
										$nextsnapdistrictid = $neighbordistrictid;
									}
								}
							}
						}
						$currentsnapdistrictid = $nextsnapdistrictid;
					}
					//Set the blocks added back to zero for this pass.
					$blocksadded = 0;
					//When the current snap district is null, it means there's no more territory to snap and we can proceed to checking available space and plotting new district if it's sufficient.
					if ($currentsnapdistrictid !== null) {
						//Track list of blocks which prefer the current snap district across all stranded groups.
						$blockdistrictpreferences = array();
						foreach(array_keys($censusblockgroups) as $groupid) {
							if ($censusblockgroups[$groupid]["snaptarget"] && array_key_exists($currentsnapdistrictid, $censusblockgroups[$groupid]["neighbordistrictblocks"])) {
								//Initialise watersheds within this group.
								$censusblockgroups[$groupid]["ws"] = array();
								//Track watersheds of blocks which border stranded area for this group.
								$neighborws = array();
								//Cycle through all neighbour blocks.
								foreach (array_keys($censusblockgroups[$groupid]["neighbordistrictblocks"]) as $neighbordistrictid) {
									//We want to eliminate any districts prior to the current district from consideration.
									if ($neighbordistrictid >= $currentsnapdistrictid) {
										foreach (array_keys($censusblockgroups[$groupid]["neighbordistrictblocks"][$neighbordistrictid]) as $neighborblockid) {
											//Add block to list of neighbouring watersheds.
											if (!array_key_exists($censusblocks[$neighborblockid]["wsid"], $neighborws)) {
												$neighborws[$censusblocks[$neighborblockid]["wsid"]] = array();
											}
											$neighborws[$censusblocks[$neighborblockid]["wsid"]][$neighborblockid] = 1;
										}
									}
								}
								//Cycle through each block in group, tracking all bordering blocks from source to point where watershed tree exits group.
								foreach (array_keys($censusblockgroups[$groupid]["blocks"]) as $blockid) {
									//Record source watershed.
									$groupsourcewsid = $censusblocks[$blockid]["wsid"];
									//Check to see whether or not the closest neighbour block has been calculated for this source watershed.
									if (!array_key_exists($groupsourcewsid, $censusblockgroups[$groupid]["ws"])) {
										//Initialise the suggested target district for all blocks in this watershed.
										$censusblockgroups[$groupid]["ws"][$groupsourcewsid]["targetdistrictid"] = null;
										//Initialise the array of blocks on the edge of the stranded territory from the starting watershed downstream to where the path exits the stranded territory.
										$censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"] = array();
										$overlapping = false;
										$currentwsid = $groupsourcewsid;
										//Descend tree.
										while (!$overlapping && $trees[$currentwsid]["parentid"] !== null) {
											//If the boundary blocks for this source watershed need to be added, add them here.
											if (array_key_exists($currentwsid, $neighborws)) {
												foreach (array_keys($neighborws[$currentwsid]) as $neighborblockid) {
													$censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"][$neighborblockid] = 1;
												}
											}
											//Check to be sure any census blocks overlap with current watershed.
											if (count($trees[$trees[$currentwsid]["parentid"]]["blocks"]) === 0) {
												//If no blocks exist in parent, descend.
												$currentwsid = $trees[$currentwsid]["parentid"];
											} else {
												$overlapping = true;
												//Look in the parent watershed for blocks in the group.  If any are found, descend.
												foreach(array_keys($trees[$trees[$currentwsid]["parentid"]]["blocks"]) as $testblockid) {
													if (array_key_exists($testblockid, $censusblockgroups[$groupid]["blocks"])) {
														$overlapping = false;
														$currentwsid = $trees[$currentwsid]["parentid"];
														break;
													}
												}
											}
										}
										//Sometimes, there will be no neighbours within the same watershed.  In this case, add all neighbour blocks which match district sequence.
										//Make sure to catch groups which are missed.  None should be!  A block should only ever be adjacent to the current snap district or one that came later.
										//Plotting blocks cannot possibly eliminate adjacency to a later district, because if it did, it would be left with no other option besides the current district to snap to.
										//Edge must always be adjacent to a later district (or be the last district).
										if (count($censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"]) === 0) {
											foreach (array_keys($censusblockgroups[$groupid]["neighbordistrictblocks"]) as $neighbordistrictid) {
												//Only add if district matches current district or was plotted later.
												if ($neighbordistrictid >= $currentsnapdistrictid) {
													foreach (array_keys($censusblockgroups[$groupid]["neighbordistrictblocks"][$neighbordistrictid]) as $neighborblockid) {
														$censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"][$neighborblockid] = 1;
													}
												}
											}
										}
										//We should now have the outflow watershed and a list of neighbour blocks in the descent.
										//Now, calculate closest block to outflow and use that as the district to snap to.
										foreach(array_keys($censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"]) as $boundaryblockid) {
											$censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"][$boundaryblockid] = getdistance($trees[$currentwsid], $censusblocks[$boundaryblockid]);
										}
										asort($censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"]);
										reset($censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"]);
										$censusblockgroups[$groupid]["ws"][$groupsourcewsid]["targetdistrictid"] = $censusblocks[key($censusblockgroups[$groupid]["ws"][$groupsourcewsid]["neighborblocks"])]["districtid"];
									}
									//If the target district for the block's watershed is the current snap district, set it in the downstream district list.
									if ($censusblockgroups[$groupid]["ws"][$groupsourcewsid]["targetdistrictid"] === $currentsnapdistrictid) {
										$blockdistrictpreferences[$blockid] = 0;
									}
								}
								//Find and mark all immediately adjacent neighbours of the current snap district.
								foreach (array_keys($censusblockgroups[$groupid]["neighbordistrictblocks"][$currentsnapdistrictid]) as $neighborblockid) {
									foreach($censusblocks[$neighborblockid]["connectedblockids"] as $blockid) {
										if (array_key_exists($blockid, $blockdistrictpreferences)) {
											$blockdistrictpreferences[$blockid] = 1;
										}
									}
								}
								//A value of 1 means the block is immediately adjacent to the current snap district.
								//The block will never select the current snap district if it is not adjacent, even if it is the preferred district.
								arsort($blockdistrictpreferences);
								reset($blockdistrictpreferences);
								while (current($blockdistrictpreferences) === 1) {
									foreach (array_keys($blockdistrictpreferences) as $blockid) {
										if ($blockdistrictpreferences[$blockid] === 1) {
											$blocksadded++;
											setblockdistrict($blockid, $currentsnapdistrictid, $districts, $censusblocks, $trees);
											if ($censusblocks[$blockid]["population"] > 0) {
												populatedown($censusblocks[$blockid]["wsid"], null, -$censusblocks[$blockid]["population"], $trees);
											}
											unset($blockdistrictpreferences[$blockid]);
											//All neighbours are now connected.
											foreach ($censusblocks[$blockid]["connectedblockids"] as $neighborblockid) {
												//Every time a block is added, all neighbours become prospects for next pass.
												if (array_key_exists($neighborblockid, $blockdistrictpreferences)) {
													$blockdistrictpreferences[$neighborblockid] = 1;
												}
												//Every time a block is added, all neighbours which are existing parts of the district must be removed from the district's edge.
												//This must be aggressive and must not take into account any other bordering districts so that stranded groups which move beyond edge may follow natural boundaries without opening back up.
												if (count($censusblockgroups[$groupid]["neighbordistrictblocks"]) > 1 && array_key_exists($neighborblockid, $districts[$currentsnapdistrictid]["edgeblocks"])) {
													unset($districts[$currentsnapdistrictid]["edgeblocks"][$neighborblockid]);
												}
											}
										} else {
											break;
										}
									}
									arsort($blockdistrictpreferences);
									reset($blockdistrictpreferences);
								}
							}
						}
					}
				}

				//Trim.  Future development:  Separate trimmed edge with seed closest to branch root from actual edge.
				if ($currentsnapdistrictid !== null) {
					$districtfinished = false;
					$prospectblocks = array();
					$prospectblocks = $districts[$currentsnapdistrictid]["edgeblocks"];
					$v = $districts[$currentsnapdistrictid]["vector"];
					//Clean up edge and make sure each one is adjacent to a later district.
					foreach (array_keys($prospectblocks) as $blockid) {
						//Set score for all edge blocks.
						$prospectblocks[$blockid] = getedgescore($censusblocks[$blockid], $v);
						$adjacenttolaterdistrict = false;
						foreach ($censusblocks[$blockid]["connectedblockids"] as $neighborblockid) {
							if ($censusblocks[$neighborblockid]["districtid"] === null || $censusblocks[$neighborblockid]["districtid"] > $currentsnapdistrictid) {
								$adjacenttolaterdistrict = true;
								break;
							}
						}
						if (!$adjacenttolaterdistrict) {
							unset($prospectblocks[$blockid]);
						}
					}
					//If no part of the edge can be found, find closest neighbour to branch root of district.
					//This generally happens when the next population center is inverted behind the branch.
					//The solution here is to recalculate the vector from the branch root to the next node which passes the entire district.
					//If this is not done, there is a possibility of generating a nonsensical geometry where the edge curves back into the district.
					//This may be the jumping off point to next version of the algorithm, with negative space calculation and proper isolation handling.
					if (count($prospectblocks) === 0) {
						$rankedfield = array();
						foreach (array_keys($districts[$currentsnapdistrictid]["blocks"]) as $blockid) {
							foreach ($censusblocks[$blockid]["connectedblockids"] as $neighborblockid) {
								if ($censusblocks[$neighborblockid]["districtid"] === null || $censusblocks[$neighborblockid]["districtid"] > $currentsnapdistrictid) {
									$rankedfield[$blockid] = getdistance($trees[$districts[$currentsnapdistrictid]["branchrootwsid"]], $censusblocks[$blockid]);
									break;
								}
							}
						}
						asort($rankedfield);
						reset($rankedfield);
						$prospectblocks[key($rankedfield)] = 1;
						//Recalculate vector.
						$v = array();
						$newtargetwsid = $trees[$districts[$currentsnapdistrictid]["branchrootwsid"]]["parentid"];
						$allblocksbehindnewtarget = false;
						while ($newtargetwsid !== null && !$allblocksbehindnewtarget) {
							$v["x"] = $trees[$newtargetwsid]["x"];
							$v["y"] = $trees[$newtargetwsid]["y"];
							$v["dx"] = $trees[$newtargetwsid]["x"] - $trees[$districts[$currentsnapdistrictid]["branchrootwsid"]]["x"];
							$v["dy"] = $trees[$newtargetwsid]["y"] - $trees[$districts[$currentsnapdistrictid]["branchrootwsid"]]["y"];
							$allblocksbehindnewtarget = true;
							foreach (array_keys($districts[$currentsnapdistrictid]["blocks"]) as $blockid) {
								//Check to see if the block passes the new target.
								if (getedgescore($censusblocks[$blockid], $v) > 0) {
									$allblocksbehindnewtarget = false;
									$newtargetwsid = $trees[$newtargetwsid]["parentid"];
									break;
								}
							}
						}
						//If the new target descended past the root, fall back to vector between edge seed and branch root.
						if ($newtargetwsid === null) {
							$v["x"] = $trees[$districts[$currentsnapdistrictid]["branchrootwsid"]]["x"];
							$v["y"] = $trees[$districts[$currentsnapdistrictid]["branchrootwsid"]]["y"];
							$v["dx"] = $trees[$districts[$currentsnapdistrictid]["branchrootwsid"]]["x"] - $censusblocks[key($prospectblocks)]["x"];
							$v["dy"] = $trees[$districts[$currentsnapdistrictid]["branchrootwsid"]]["y"] - $censusblocks[key($prospectblocks)]["y"];
						}
						//Save new vector to district object.
						$districts[$currentsnapdistrictid]["vector"] = $v;
					}
					//Report cases where no prospects were found.
					//This may occur with final district if somehow stranded territory remains on the last pass, but the condition shouldn't ever arise.
					if (count($prospectblocks) === 0) {
						echo ("No removal prospects were found for district $currentsnapdistrictid.<BR>");
					}
					$nextblockid = null;
					//This is the block removal loop.
					while (!$districtfinished) {
						//Find next block to remove.  This should always be the largest score (reverse of assignment).
						arsort($prospectblocks);
						reset($prospectblocks);
						$nextblockid = key($prospectblocks);
						//If the perpendicular edge score becomes negative, remove the pivot.
						if ($nextblockid !== null && array_key_exists("sign", $v) && getperpendiculardistance($censusblocks[$nextblockid], $v) < 0) {
							unset($v["sign"]);
							foreach (array_keys($prospectblocks) as $blockid) {
								$prospectblocks[$blockid] = getedgescore($censusblocks[$blockid], $v);
							}
							arsort($prospectblocks);
							reset($prospectblocks);
							$nextblockid = key($prospectblocks);
						}
						//Check to see if district is finished.
						//If there is no next prospect, or if the district would be equal to or smaller than the size of the target district population, the district is done.
						if (
							$nextblockid === null
							|| $districts[$currentsnapdistrictid]["population"] - $censusblocks[$nextblockid]["population"] <= $districtsize
							
						) {
							$districtfinished = true;
						} else {
							//Remove the block from the district.
							unsetblockdistrict($nextblockid, $currentsnapdistrictid, $districts, $censusblocks, $trees);
							if ($censusblocks[$nextblockid]["population"] > 0) {
								populatedown($censusblocks[$nextblockid]["wsid"], null, $censusblocks[$nextblockid]["population"], $trees);
							}
							//Add neighbours of block to prospects.
							foreach($censusblocks[$nextblockid]["connectedblockids"] as $blockid) {
								//If the neighbour is part of the block group and still has the same districtID, it can be added.
								if ($censusblocks[$blockid]["districtid"] === $currentsnapdistrictid) {
									$prospectblocks[$blockid] = getedgescore($censusblocks[$blockid], $v);
								}
							}
							//Unset block.
							unset($prospectblocks[$nextblockid]);
							$nextblockid = null;
						}
					}
					//Check all blocks of resulting structure to make sure they are contiguous.  Remove all minor groups.
					//This may at times remove significant parts of the geography.  This is an ongoing research problem.
					//Use group building process to add all blocks within district to discrete groups.
					$currentdistrictstrandedgroups = array();
					foreach (array_keys($districts[$currentsnapdistrictid]["blocks"]) as $blockid) {
						if (!groupscontainblock($blockid, $currentdistrictstrandedgroups) && $censusblocks[$blockid]["districtid"] === $currentsnapdistrictid) {
							$currentdistrictstrandedgroups[] = array("population" => 0, "centroid" => array("x" => 0.0, "y" => 0.0, "thearea" => 0.0),
								"blocks" => array(), "neighbordistrictblocks" => array()
							);
							addblockstogroup($blockid, null, $currentsnapdistrictid, $currentdistrictstrandedgroups[count($currentdistrictstrandedgroups) - 1], $censusblocks, $trees);
						}
					}
					//If there's more than one group, dump all but the largest one.
					if (count($currentdistrictstrandedgroups) > 1) {
						$currentdistrictlargestgroupid = null;
						foreach (array_keys($currentdistrictstrandedgroups) as $groupid) {
							if ($currentdistrictlargestgroupid === null || $currentdistrictstrandedgroups[$groupid]["population"] > $currentdistrictstrandedgroups[$currentdistrictlargestgroupid]["population"]) {
								$currentdistrictlargestgroupid = $groupid;
							}
						}
						//Loop again, this time unsetting any minor groups.
						foreach (array_keys($currentdistrictstrandedgroups) as $groupid) {
							if ($currentdistrictlargestgroupid !== $groupid) {
								foreach(array_keys($currentdistrictstrandedgroups[$groupid]["blocks"]) as $blockid) {
									unsetblockdistrict($blockid, $currentsnapdistrictid, $districts, $censusblocks, $trees);
									if ($censusblocks[$blockid]["population"] > 0) {
										populatedown($censusblocks[$blockid]["wsid"], null, $censusblocks[$blockid]["population"], $trees);
									}
									//If this comes out of the district, it must come out of the edge as well.
									unset($prospectblocks[$blockid]);
								}
							}
						}
					}
					//At the end, set edge blocks to new array.
					$districts[$currentsnapdistrictid]["edgeblocks"] = array();
					$districts[$currentsnapdistrictid]["edgeblocks"] = $prospectblocks;

					//Reset block counter to find a new district.
					$blocksadded = null;
					//Reset group count to make sure at least one more analysis of open space occurs.
					$strandedgroupcount = null;
				}
				//Before continuing to district definition, check to see if there is a single open group of census blocks and if there is enough space in them to fit a new district.
				//If there isn't, descend one and reset group count and current district to start all over again.
				if ($strandedgroupcount === 0) {
					//Find largest group which is not a snap prospect by population.
					$districttargetgroupid = null;
					foreach(array_keys($censusblockgroups) as $groupid) {
						if ($districttargetgroupid === null || $censusblockgroups[$groupid]["population"] > $censusblockgroups[$districttargetgroupid]["population"]) {
							$districttargetgroupid = $groupid;
						}
					}
					//Once it gets here, there should be a single group of open territory.  Check to be sure there is, and if there isn't enough space to fit the next district, descend and start the whole process over from scratch.
					if (!$lastdistrict && $districttargetgroupid !== null && $censusblockgroups[$districttargetgroupid]["population"] < $districtsize && $trees[$wsid]["parentid"] !== null) {
						$wsid = $trees[$wsid]["parentid"];
						//Reset the starting parameters.
						$strandedgroupcount = null;
						$currentsnapdistrictid = null;
						$blocksadded = null;
					}
				}
			}
			//After there are no more stranded groups, close watersheds.
			closewatersheds($wsid, $wsid, $districts, $censusblocks, $trees);

			///////////////////////////////////
			//Build district from block group//
			///////////////////////////////////
			
			//1.  Find starting block.
			//2.  Add blocks to district using straight edge, pivoting when changing direction.
			//3.  Stop when population threshold is reached.
			//4.  If another pass of district is required with an edge perpendicular to a boundary, back up district result and run a second pass.
			//5.  Compare different test cases and save district block values for test with shortest edge.
			
			//Set district ID
			$districtid = count($districts) + 1;
			
			//Report progress.
			echo ("District: ".$districtid.". Branch root WSID: ".$wsid.". Branch root population: ".number_format($trees[$wsid]["branchpopulation"])."<BR>");flush();

			//When setting district, shoot for supplied district size if not the last district, and shoot for all available population otherwise.
			if ($lastdistrict) {
				$targetpopulation = $censusblockgroups[$districttargetgroupid]["population"];
			} else {
				$targetpopulation = $districtsize;
			}
			//Initialise prospects and blocks which make up district.
			$prospectblocks = array();
			$districtblocks = array();
			$assignedpopulation = 0;
			//Downstream district is next point down the tree where a second full district can be created, or the root, whichever comes first.
			//If the edges of each district can look ahead this way, it should tend to create more convex, rounded polygons.
			//The exception to this rule is when the branch root is on the boundary, where parallel edges are sometimes shorter.
			$centerededgetargetwsid = $wsid;
			if (!$trees[$wsid]["boundary"]) {
				while ($trees[$centerededgetargetwsid]["parentid"] !== null && $trees[$centerededgetargetwsid]["branchpopulation"] < $targetpopulation + $districtsize) {
					$centerededgetargetwsid = $trees[$centerededgetargetwsid]["parentid"];
				}
			}
			//The boundary target has the same population target, but all watersheds in path must also be on the boundary.
			$boundarytargetwsid = null;
			if ($trees[$wsid]["boundary"]) {
				$boundarytargetwsid = $wsid;
				while ($trees[$boundarytargetwsid]["parentid"] !== null && $trees[$boundarytargetwsid]["branchpopulation"] < $targetpopulation + $districtsize && $trees[$trees[$boundarytargetwsid]["parentid"]]["boundary"]) {
					$boundarytargetwsid = $trees[$boundarytargetwsid]["parentid"];
				}
			}
			//Gather all watersheds which overlap targeted block group and store the distance to watershed target for each.
			$groupwatersheds = array();
			foreach(array_keys($censusblockgroups[$districttargetgroupid]["blocks"]) as $blockid) {
				if (!array_key_exists($censusblocks[$blockid]["wsid"], $groupwatersheds)) {
					//If a boundary target has been identified, use that to populate distances within watershed group.  If not, use the centered edge target.
					//These should usually be identical.  Right now, the watershed group is only used for calculating starting boundary watershed.
					if ($boundarytargetwsid !== null) {
						$groupwatersheds[$censusblocks[$blockid]["wsid"]] = getdistance($trees[$boundarytargetwsid], $trees[$censusblocks[$blockid]["wsid"]]);
					} else {
						$groupwatersheds[$censusblocks[$blockid]["wsid"]] = getdistance($trees[$centerededgetargetwsid], $trees[$censusblocks[$blockid]["wsid"]]);
					}
				}
			}
			//Travel all boundary paths from branch root to find farthest watershed along contiguous boundary path.  A branch not on boundary will return null value.
			$boundarysourcewsid = getfarthestboundaryws($wsid, $groupwatersheds, $trees);
			//If the boundary source and target are the same, try to find the next watershed down from target with an additional full district.
			if ($boundarysourcewsid !== null && $boundarysourcewsid === $boundarytargetwsid) {
				$nexttargetpopulation = (int)ceil(($trees[$boundarytargetwsid]["branchpopulation"] - $targetpopulation + 1) / $districtsize) * $districtsize + $targetpopulation;
				//All parts of path must be on the boundary.
				while ($trees[$boundarytargetwsid]["parentid"] !== null && $trees[$boundarytargetwsid]["branchpopulation"] < $nexttargetpopulation && $trees[$trees[$boundarytargetwsid]["parentid"]]["boundary"]) {
					$boundarytargetwsid = $trees[$boundarytargetwsid]["parentid"];
				}
			}
			//If the source and the target are still the same, no boundary process should take place.
			if ($boundarysourcewsid === $boundarytargetwsid) {
				$boundarysourcewsid = null;
				$boundarytargetwsid = null;
			}
			//Reset vector so it doesn't use remnant pivot values from above.
			$v = array();
			//Default to centered edge process.
			$boundaryprocess = false;
			//Always calculate farthest block from target.
			$rankedfield = array();
			foreach(array_keys($censusblockgroups[$districttargetgroupid]["blocks"]) as $blockid) {
				$rankedfield[$blockid] = getdistance($censusblocks[$blockid], $trees[$centerededgetargetwsid]);
			}
			arsort($rankedfield);
			reset($rankedfield);
			$centerededgeblockid = key($rankedfield);
			//Initialise centered edge process.
			if (count($prospectblocks) === 0) {
				$prospectblocks[$centerededgeblockid] = 0.0;
				$v["x"] = $censusblocks[$centerededgeblockid]["x"];
				$v["y"] = $censusblocks[$centerededgeblockid]["y"];
				$v["dx"] = $trees[$centerededgetargetwsid]["x"] - $censusblocks[$centerededgeblockid]["x"];
				$v["dy"] = $trees[$centerededgetargetwsid]["y"] - $censusblocks[$centerededgeblockid]["y"];
			}
			$edgelength = null;
			$edgeblocks = array();
			//This is for backing up parameters of the centered edge process so they can be restored if it scores higher than the boundary process.
			$centerededgedistrictparameters = array();
			//$targetwsid may be altered as process goes on.
			$targetwsid = $centerededgetargetwsid;
			while (count($prospectblocks) > 0) {
				asort($prospectblocks);
				reset ($prospectblocks);
				//For consideration, the prospect must be behind the advancing edge.
				if (current($prospectblocks) <= 0.0) {
					//Grab block farthest back from edge.
					$nextblockid = key($prospectblocks);
					//Check to see if the district is done.
					if (abs($assignedpopulation - $targetpopulation) < abs($assignedpopulation + $censusblocks[$nextblockid]["population"]- $targetpopulation)) {
						//Calculate edge length before exiting.  First, calculate edge.
						$edgeblocks = array();
						//Populate edge blocks.
						foreach (array_keys($prospectblocks) as $blockid) {
							foreach ($censusblocks[$blockid]["connectedblockids"] as $neighborblockid) {
								if (array_key_exists($neighborblockid, $districtblocks) && !array_key_exists($neighborblockid, $edgeblocks)) {
									$edgeblocks[$neighborblockid] = getedgescore($censusblocks[$neighborblockid], $v);
								}
							}
						}
						$edgelength = getedgelength($v, $edgeblocks, $censusblocks);
						$prospectblocks = array();
						//Check to see if second pass should be done using boundary process.
						//On occasion, setting the target to a branch root which is on a boundary can yield a shorter artificial border with the centered edge process.
						//There's no way to tell which will be better without testing each approach.
						if ($boundarysourcewsid !== null && $boundarytargetwsid !== null && !array_key_exists("districtblocks", $centerededgedistrictparameters) && count($districtblocks) > 0) {
							//Back up variables from centered edge pass.
							$centerededgedistrictparameters["districtblocks"] = $districtblocks;
							$centerededgedistrictparameters["edgeblocks"] = $edgeblocks;
							$centerededgedistrictparameters["edgelength"] = $edgelength;
							$centerededgedistrictparameters["targetwsid"] = $targetwsid;
							$centerededgedistrictparameters["v"] = $v;
							$centerededgedistrictparameters["lastblockid"] = $lastblockid;
							//Initialise variables for boundary process.
							$boundaryprocess = true;
							$assignedpopulation = 0;
							$edgelength = null;
							$districtblocks = array();
							$prospectblocks = array();
							$edgeblocks = array();
							//Set vector first to pointer from source to target.
							$v = array();
							$v["x"] = $trees[$boundarysourcewsid]["x"];
							$v["y"] = $trees[$boundarysourcewsid]["y"];
							$v["dx"] = $trees[$boundarytargetwsid]["x"] - $trees[$boundarysourcewsid]["x"];
							$v["dy"] = $trees[$boundarytargetwsid]["y"] - $trees[$boundarysourcewsid]["y"];
							//Calculate farthest block away based on boundary vector.
							$rankedfield = array();
							foreach(array_keys($censusblockgroups[$districttargetgroupid]["blocks"]) as $blockid) {
								$rankedfield[$blockid] = getperpendiculardistance($censusblocks[$blockid], $v);
							}
							asort($rankedfield);
							reset($rankedfield);
							//Create default seed for prospects.
							$prospectblocks[key($rankedfield)] = 0.0;
							$sourcewsid = $boundarysourcewsid;
							$targetwsid = $boundarytargetwsid;
						}
					} else {
						//The block does not overflow the target district population.  Set it.
						$districtblocks[$nextblockid] = 1;
						$assignedpopulation += $censusblocks[$nextblockid]["population"];
						unset($prospectblocks[$nextblockid]);
						//Record last block set.  This will determine progress of the edge in comparison with target watershed.
						$lastblockid = $nextblockid;
						foreach($censusblocks[$nextblockid]["connectedblockids"] as $neighborblockid) {
							if (!array_key_exists($neighborblockid, $districtblocks) && !array_key_exists($neighborblockid, $prospectblocks)
								&& array_key_exists($neighborblockid, $censusblockgroups[$districttargetgroupid]["blocks"])
							) {
								$prospectblocks[$neighborblockid] = getedgescore($censusblocks[$neighborblockid], $v);
							}
						}
						//If it hits the boundary and isn't already running the boundary process, check to see if there is an unbroken boundary path
						//from the current watershed to the branch root.  If there is, it should switch to the boundary process.
						if (!$boundaryprocess && $censusblocks[$nextblockid]["boundary"]) {
							$currentwsid = $censusblocks[$nextblockid]["wsid"];
							while ($currentwsid !== $wsid && $trees[$currentwsid]["boundary"]) {
								$currentwsid = $trees[$currentwsid]["parentid"];
							}
							if ($wsid === $currentwsid && $boundarytargetwsid !== null) {
								$boundaryprocess = true;
								$sourcewsid = $censusblocks[$nextblockid]["wsid"];
								$targetwsid = $boundarytargetwsid;
							}
						}
					}
				} else {
					//Scores are now positive.  Find new advancing edge.
					//Just in case there is some slight offset in the maths between pivoting edge and descending edge, make another pass if a pivot has been requested.
					if (array_key_exists("sign", $v)) {
						unset($v["sign"]);
					} else {
						//The last edge should never have a pivot here.  Reset zero point of last edge to next block so ranking of target watersheds is never zero in boundary comparison.
						$nextblockid = key($prospectblocks);
						$nextv = array();
						$nextv = $v;
						$nextv["x"] = $censusblocks[$nextblockid]["x"];
						$nextv["y"] = $censusblocks[$nextblockid]["y"];
						
						//The next target population is one whole district more than the population in the current target.
						//If edge passes target, descend tree until next target is reached.
						$nexttargetpopulation = (int)ceil(($trees[$targetwsid]["branchpopulation"] - $targetpopulation + 1) / $districtsize) * $districtsize + $targetpopulation;
						$nexttargetwsid = $targetwsid;
						while ($trees[$nexttargetwsid]["parentid"] !== null && $trees[$nexttargetwsid]["branchpopulation"] < $nexttargetpopulation) {
							$nexttargetwsid = $trees[$nexttargetwsid]["parentid"];
						}
						//Back up vector.
						$lastv = $v;
						//The boundary process has been requested.  Use boundary vectors from source to target watershed.
						if ($boundaryprocess) {
							//If the edge has passed the target, set new target and use the old target as the source.
							if (getperpendiculardistance($trees[$targetwsid], $nextv) <= 0.0 || $sourcewsid === $targetwsid) {
								$sourcewsid = $targetwsid;
								$targetwsid = $nexttargetwsid;
							}
							//If the edge hasn't passed the boundary target, move the source down the tree until entire path to branch root is in front of perpendicular.
							//After the target has been passed, skip nodes between one target and the next.
							if ($targetwsid === $boundarytargetwsid) {
								$currentwsid = $sourcewsid;
								while ($currentwsid !== null && $currentwsid !== $targetwsid) {
									if (getperpendiculardistance($trees[$currentwsid], $nextv) <= 0.0) {
										//The source should always be the last one behind the line in the descent.
										$sourcewsid = $currentwsid;
									}
									$currentwsid = $trees[$currentwsid]["parentid"];
								}
							}
							if ($sourcewsid !== $targetwsid) {
								//If the source and target are different, construct a vector from the former to the latter.
								$v["dx"] = $trees[$targetwsid]["x"] - $trees[$sourcewsid]["x"];
								$v["dy"] = $trees[$targetwsid]["y"] - $trees[$sourcewsid]["y"];
								$v["x"] = $trees[$targetwsid]["x"];
								$v["y"] = $trees[$targetwsid]["y"];
								//Calculate new scores for prospects.  Stop point score must be greater than lowest score to avoid an infinite loop.
								foreach (array_keys($prospectblocks) as $blockid) {
									$prospectblocks[$blockid] = getperpendiculardistance($censusblocks[$blockid], $v);
								}
								//Find next stopping point in boundary path.
								$currentwsid = $trees[$sourcewsid]["parentid"];
								$rankedfield = array();
								while ($currentwsid !== null && $currentwsid !== $trees[$targetwsid]["parentid"]) {
									if (getperpendiculardistance($trees[$currentwsid], $v) > min($prospectblocks)) {
										$rankedfield[$currentwsid] = getperpendiculardistance($trees[$currentwsid], $v);
									}
									$currentwsid = $trees[$currentwsid]["parentid"];
								}
								if (count($rankedfield) > 0) {
									asort($rankedfield);
									reset($rankedfield);
									$v["x"] = $trees[key($rankedfield)]["x"];
									$v["y"] = $trees[key($rankedfield)]["y"];
								}
							} else {
								//If the source and target are the same, it should be the root of the tree.  Locate the far side of the field and point to that.
								$rankedfield = array();
								foreach(array_keys($censusblockgroups[$districttargetgroupid]["blocks"]) as $blockid) {
									$rankedfield[$blockid] = getperpendiculardistance($censusblocks[$blockid], $v);
								}
								arsort($rankedfield);
								reset($rankedfield);
								$v["x"] = $censusblocks[key($rankedfield)]["x"];
								$v["y"] = $censusblocks[key($rankedfield)]["y"];
							}
						} else {
							//The edge has passed the center block in the centered edge process.  If the edge has passed the target as well, set new target.
							if (getperpendiculardistance($trees[$targetwsid], $nextv) <= 0.0) {
								$targetwsid = $nexttargetwsid;
							}
							//This locates new centerpoint of square edge.  dx/dy is perpendicular now.
							swap($v["dx"], $v["dy"]);
							$v["dx"] = -$v["dx"];
							foreach (array_keys($prospectblocks) as $blockid) {
								$prospectblocks[$blockid] = getperpendiculardistance($censusblocks[$blockid], $v);
							}
							$targetpscore = (min($prospectblocks) + max($prospectblocks)) / 2.0;
							$centerededgeblockid = null;
							foreach ($prospectblocks as $blockid => $pscore) {
								if ($centerededgeblockid === null || abs($pscore - $targetpscore) < abs($prospectblocks[$centerededgeblockid] - $targetpscore)) {
									$centerededgeblockid = $blockid;
								}
							}
							//Set vector and prospects to new values.
							$v["x"] = $censusblocks[$centerededgeblockid]["x"];
							$v["y"] = $censusblocks[$centerededgeblockid]["y"];
							$v["dx"] = $trees[$targetwsid]["x"] - $censusblocks[$centerededgeblockid]["x"];
							$v["dy"] = $trees[$targetwsid]["y"] - $censusblocks[$centerededgeblockid]["y"];
						}
						//Edge is all blocks in district adjacent to prospects.
						$edgeblocks = array();
						foreach(array_keys($prospectblocks) as $blockid) {
							foreach($censusblocks[$blockid]["connectedblockids"] as $neighborblockid) {
								if (array_key_exists($neighborblockid, $districtblocks) && !array_key_exists($neighborblockid, $edgeblocks)) {
									$edgeblocks[$neighborblockid] = getperpendiculardistance($censusblocks[$neighborblockid], $v);
								}
							}
						}
						//Reverse sort using new vector.
						arsort($edgeblocks);
						reset($edgeblocks);
						//Check to see if any prospects are behind potential pivot point.
						foreach (array_keys($prospectblocks) as $blockid) {
							if (getperpendiculardistance($censusblocks[$blockid], $v) <= current($edgeblocks)) {
								//If so, set edge point as pivot and calculate vector rotation direction.
								$v["x"] = $censusblocks[key($edgeblocks)]["x"];
								$v["y"] = $censusblocks[key($edgeblocks)]["y"];
								$anglesign = getangledistance($lastv, $v);
								//Use the sign on the delta between the last vector and the new one to set direction.
								if ($anglesign < 0) {
									$v["sign"] = -1;
								} else {
									$v["sign"] = 1;
								}
								break;
							}
						}
					}
					//Set prospect scores given new vector.
					foreach (array_keys($prospectblocks) as $blockid) {
						$prospectblocks[$blockid] = getedgescore($censusblocks[$blockid], $v);
					}
				}
			}
			//District tests are complete.  Select one based on whichever has the shortest artificial edge.
			//Check if a backup was saved for the centered edge process.
			if (array_key_exists("edgelength", $centerededgedistrictparameters)) {
				if ($centerededgedistrictparameters["edgelength"] < $edgelength) {
					//echo ("Centered edge is smaller. ".$centerededgedistrictparameters["edgelength"]." vs $edgelength.<BR>");
					//Restore variables.
					$districtblocks = array();
					$districtblocks = $centerededgedistrictparameters["districtblocks"];
					$edgeblocks = array();
					$edgeblocks = $centerededgedistrictparameters["edgeblocks"];
					$targetwsid = $centerededgedistrictparameters["targetwsid"];
					$v = $centerededgedistrictparameters["v"];
					$lastblockid = $centerededgedistrictparameters["lastblockid"];
				} else {
					//echo ("Boundary edge is smaller. $edgelength vs ".$centerededgedistrictparameters["edgelength"].".<BR>");
				}
			} else {
				//echo ("No contest result.  No boundary detected.  Centered edge length: $edgelength.<BR>");
			}

			//Initialise district.
			$districts[$districtid]["branchrootwsid"] = $wsid;
			
			//Identify closest edge block to downstream watershed for block removal sequence.  If branch root is already behind the edge, use the target watershed instead.
			if (getedgescore($censusblocks[$lastblockid], $v) > getedgescore($trees[$wsid], $v)) {
				$edgetargetwsid = $targetwsid;
			} else {
				$edgetargetwsid = $wsid;
			}

			//Find new pivot point for potential reduction of district.  This is the point on the edge farthest from the current pivot point.
			if (array_key_exists("sign", $v)) {
				$rankedfield = array();
				foreach (array_keys($edgeblocks) as $blockid) {
					$rankedfield[$blockid] = getdistance($censusblocks[$blockid], $v);
				}
				arsort($rankedfield);
				reset($rankedfield);
				$v["sign"] = -$v["sign"];
				$v["x"] = $censusblocks[key($rankedfield)]["x"];
				$v["y"] = $censusblocks[key($rankedfield)]["y"];
			}

			//Set boundary calculation vector.
			$districts[$districtid]["vector"] = $v;
			//Prime edge with closest point to branch root for trim cycle.  As trim passes complete, the edge may become more spread out.
			//Future research:  Test negative space removal instead of starting with farthest block from branch root.  Point to next node and open like umbrella.
			//Future research:  Experiment with more accurate edge measurement and not simply gross distance from end to end.  Edges may be separated by natural boundaries, which should be preferred.
			$rankedfield = array();
			foreach (array_keys($edgeblocks) as $blockid) {
				$rankedfield[$blockid] = getdistance($trees[$edgetargetwsid], $censusblocks[$blockid]);
			}
			asort($rankedfield);
			reset($rankedfield);
			$districts[$districtid]["edgeblocks"] = array();
			if (count($rankedfield) > 0) {
				$districts[$districtid]["edgeblocks"][key($rankedfield)] = getedgescore($censusblocks[key($rankedfield)], $v);
			}
			$districts[$districtid]["centroid"]["x"] = 0.0;
			$districts[$districtid]["centroid"]["y"] = 0.0;
			$districts[$districtid]["centroid"]["thearea"] = 0.0;
			$districts[$districtid]["population"] = 0;
			$districts[$districtid]["blocks"] = array();
			foreach (array_keys($districtblocks) as $blockid) {
				//Set block.
				setblockdistrict($blockid, $districtid, $districts, $censusblocks, $trees);
				//Within the branch, we can just populate down to the branch root.  When closing, it has to be all the way.
				if ($censusblocks[$blockid]["population"] > 0) {
					populatedown($censusblocks[$blockid]["wsid"], $wsid, -$censusblocks[$blockid]["population"], $trees);
				}
			}
			//Populate downstream values.
			populatedown($trees[$wsid]["parentid"], null, -$districts[$districtid]["population"], $trees);
			//After district is completed, try to close watersheds which have been completely assigned.
			closewatersheds($wsid, $wsid, $districts, $censusblocks, $trees);
		}
	}
}


////////
//MAIN//
////////

//Get state name from request.
$statename = str_replace("'", "", request("state"));
if ($statename === null || $statename === "") {
	?>
	<form method = "post" name = "theform">
	<h2>Select state to process.</h2>
	<select name = "state">
	<?php
	$rs = $currentdb->execute("select name, null::int as placeholder from wdcensusstates order by 1;");
	while ($row = pg_fetch_array($rs)) {
		?><option value = "<?php echo ($row["name"]);?>"><?php echo ($row["name"]);?></option><?php
	}
	?><option value = "all">All</option></select><br/><br/><input type = "submit" value = "GO" style = "border-radius:4px;" /><br /><br /></form><?php
}

//Initialise output array for database.
$copyout = array();
//Initialise timer.
$starttime = time();

//Loop through the states one at a time.  If you don't cast to a float, you get a slightly different district size.
$sql = "select stateid, population, representatives, round(population::double precision / representatives::double precision) as districtsize, name From wdcensusstates where representatives > 0";
//Only process all states if user submits "states=all"
if (strtolower($statename) !== "all") {
	$sql .= " and name ilike '$statename'";
}
$sql .= " order by name;";
$staters = $currentdb->execute($sql);
while ($row = pg_fetch_array($staters)) {
	$stateid = (int)$row["stateid"];
	$districtsize = (int)$row["districtsize"];
	echo ("<h3>Now processing: ".$row["name"].". Voters per district: ".number_format($districtsize)."</h3>"); flush();

	//Initialise trees and network.
	$trees = array();
	$rs = $currentdb->execute("select a.id as wsid, a.parentid, a.islandid, a.population, st_x(b.exitmercgeom) as x, st_y(b.exitmercgeom) as y,
		st_area(a.mercgeom) as thearea from wdwstree a inner join wdws b on a.id = b.id where a.stateid = $stateid order by a.id;");
	while ($row = pg_fetch_array($rs)) {
		//The branch root is used to label all watersheds starting from a particular node.
		$trees[$row["wsid"]]["branchrootwsid"] = null;
		//Coordinates correspond to exit point of each watershed.
		$trees[$row["wsid"]]["x"] = floatval($row["x"]);
		$trees[$row["wsid"]]["y"] = floatval($row["y"]);
		//Boundary watersheds have at least one dimension making up the boundary of the larger territory.
		$trees[$row["wsid"]]["boundary"] = false;
		//Once all blocks in the branch have been assigned, branch is closed.
		$trees[$row["wsid"]]["closed"] = false;
		//Number of blocks within a watershed which still have not been assigned to a district.
		$trees[$row["wsid"]]["openblockcount"] = 0;
		//The branch population represents the maximum available population that may be added if the entire branch is added to a district.  This number changes as processing continues.
		$trees[$row["wsid"]]["branchpopulation"] = NULL;
		//The population of a watershed is calculated from the associated census blocks.
		$trees[$row["wsid"]]["population"] = 0;
		//Census blocks within watershed.
		$trees[$row["wsid"]]["blocks"] = array();
		//Parent of watershed.
		$trees[$row["wsid"]]["parentid"] = NULL;
		//Children of watershed.  Order obeys right-hand rule after parent of watershed.  Details are below.
		$trees[$row["wsid"]]["children"] = array();
	}

	//Add connexion between parent and children.  All watersheds must be prepared above, or the array will generate an access error.
	//The order of the children does not appear to affect the effective district composition, but it will shuffle the district IDs.
	//For this reason, it's better to have a deterministic method of ordering upstream children.  The children should follow the right-hand rule after the parent OR after the longest border boundary.
	//If there is no border boundary between two watersheds, the children will be sorted by longest unattached border boundary, and then by area in descending order.
	$rs = $currentdb->execute("
		--Choose order of longest continuous segment:
		drop table if exists _distinctconnections; select b.* into temp _distinctconnections from (
			select distinct first_value(a.id) over (partition by a.wsid0, a.wsid1 order by st_length(a.mercgeom) desc, a.id) as id from wdwsconnections a
			inner join wdws b on a.wsid0 = b.id where b.stateid = $stateid order by 1
		) a inner join wdwsconnections b on a.id = b.id order by 1;

		--No ordering on island networks!  If there's no proximity, order shouldn't matter.  It can be taken care of through sorting by area.
		select a.parentid, a.wsid, a.thearea from (
			select a.parentid, a.id as wsid, coalesce(c.id, d.id) as ordinal, coalesce(e.id, d.id) as parentordinal, st_area(a.mercgeom) as thearea
			from wdwstree a left join wdwstree b on a.parentid = b.id
			left join _distinctconnections c on c.wsid0 = a.parentid and c.wsid1 = a.id
			--This one should find the single coastal segment.  There should be a maximum of one per poly
			left join _distinctconnections d on d.wsid0 = a.parentid and d.wsid1 = 0
			left join _distinctconnections e on e.wsid0 = a.parentid and e.wsid1 = b.parentid where a.stateid = $stateid order by 1, 3
		) a left join (select wsid0, min(id) as themin, max(id) as themax from _distinctconnections group by 1 order by 1) b on a.parentid = b.wsid0
		order by a.parentid, case when a.parentordinal > a.ordinal then b.themax + 1 + a.ordinal - b.themin else a.ordinal end, a.thearea desc, a.wsid;
	");
	while ($row = pg_fetch_array($rs)) {
		if ($row["parentid"] !== NULL) {
			$trees[$row["wsid"]]["parentid"] = (int)$row["parentid"];
			array_push ($trees[$row["parentid"]]["children"], (int)$row["wsid"]);
		}
	}

	//Track cases where watersheds lie on the edge of the map.  Since the watersheds are much more detailed along water boundaries, the better information actually comes from there.
	$rs = $currentdb->execute("select id as wsid, null::int as placeholder from wdws where boundary and stateid = $stateid;");
	while ($row = pg_fetch_array($rs)) {
		$trees[$row["wsid"]]["boundary"] = true;
	}

	//Initialise state timer.
	$checkpoint = time();
	//Load census blocks.
	$censusblocks = array();
	$rs = $currentdb->execute("select id, population, boundary, st_x(st_centroid(mercgeom)) as x, st_y(st_centroid(mercgeom)) as y, st_area(mercgeom) as thearea from wdcensusblocks where stateid = $stateid order by id;");
	while ($row = pg_fetch_array($rs)) {
		$censusblocks[$row["id"]]["population"] = (int)($row["population"]);
		if ($row["boundary"] === "t") {
			$censusblocks[$row["id"]]["boundary"] = true;
		} else {
			$censusblocks[$row["id"]]["boundary"] = false;
		}
		$censusblocks[$row["id"]]["x"] = floatval($row["x"]);
		$censusblocks[$row["id"]]["y"] = floatval($row["y"]);
		$censusblocks[$row["id"]]["thearea"] = floatval($row["thearea"]);
		$censusblocks[$row["id"]]["districtid"] = null;
		$censusblocks[$row["id"]]["connectedblockids"] = array();
	}
	echo ("Census blocks loaded. ".number_format((time() - $checkpoint) / 60, 2)." minutes <BR>"); $checkpoint = time(); flush();

	//Load connexions between census blocks.
	$rs = $currentdb->execute("select a.blockid0, a.blockid1 from (
		select distinct blockid0, blockid1 from wdcensusblockislandconnections 
		union select blockid0, blockid1 from wdcensusblockconnections
	) a inner join wdcensusblocks b on a.blockid0 = b.id
	inner join wdcensusblocks c on a.blockid1 = c.id where b.stateid = $stateid and c.stateid = $stateid order by 1, 2;");
	while ($row = pg_fetch_array($rs)) {
		$censusblocks[$row["blockid0"]]["connectedblockids"][] = (int)($row["blockid1"]);
	}
	echo ("Census block connections loaded. ".number_format((time() - $checkpoint) / 60, 2)." minutes <BR>"); $checkpoint = time(); flush();

	//Load census blocks within watersheds.
	$rs = $currentdb->execute("select a.*, b.population, b.boundary from wdcensusws a inner join wdcensusblocks b on a.blockid = b.id where b.stateid = $stateid order by wsid, blockid;");
	while ($row = pg_fetch_array($rs)) {
		$trees[$row["wsid"]]["openblockcount"]++;
		$trees[$row["wsid"]]["population"] += (int)$row["population"];
		$trees[$row["wsid"]]["blocks"][(int)($row["blockid"])] = 1;
		$censusblocks[$row["blockid"]]["wsid"] = (int)$row["wsid"];
	}
	echo ("Census block - watershed connections loaded. ".number_format((time() - $checkpoint) / 60, 2)." minutes <BR>"); $checkpoint = time(); flush();

	//Find root of entire tree.  There should only be one...
	foreach ($trees as $wsid => $value) {
		if ($value["parentid"] === NULL) {
			$rootwsid = $wsid;
			break;
		}
	}

	//Initialise branch population of all nodes.
	populatebranches($rootwsid, $trees);
	//Initialise district list.
	$districts = array();
	//Loop until all population has been assigned.
	$pass = 1;
	while ($trees[$rootwsid]["branchpopulation"] > 0) {
		echo ("<br>Pass: ".$pass.". Population remaining: ".number_format($trees[$rootwsid]["branchpopulation"])."<hr>"); flush();
		trimtrees($rootwsid, $districtsize, $districts, $censusblocks, $trees);
		$pass++;
	}
	//Populate district block array for export.
	foreach($censusblocks as $blockid => $censusblock) {
		if ($censusblocks[$blockid]["districtid"] !== null) {
			$copyout[] = $blockid."\t".$censusblocks[$blockid]["districtid"];
		}
	}

	/*
	//Debug.  Dump all edges to make sure they make sense.
	echo ("<BR>");
	foreach (array_keys($districts) as $districtid) {
		foreach (array_keys($districts[$districtid]["edgeblocks"]) as $blockid) {
			echo ("$blockid, ");
		}
	}
	echo ("<BR>");
	*/

}

//Do not touch database if state has not yet been selected.
if ($statename !== null && $statename !== "") {
	//Write output table to DB.
	pg_query($currentdb->connection, "drop table if exists wddistrictblocks; create table wddistrictblocks(id int primary key, districtid int);");
	pg_copy_from($currentdb->connection, "wddistrictblocks", $copyout);
	?><hr>Table wddistrictblocks created and populated.<BR><?php

	//Creates districts from census blocks.  Depending on the size of the state, this can be time-consuming!  If testing the algorithm, it is advised to comment the statement and run it manually when needed.
	$currentdb->execute("
		drop table if exists wddistricts; 
		select b.stateid, a.districtid, sum(b.population) as population, st_unaryunion(st_collect(b.mercgeom)) as mercgeom into wddistricts
		from wddistrictblocks a inner join wdcensusblocks b on a.id = b.id group by 1,2 order by 1,2;
	");
	echo ("Table wddistricts created and populated.<BR>");

	?>Total time elapsed: <?php echo (number_format((time() - $starttime) / 60, 2));?> minutes<BR>
	<a href = "">Start Over</a><?php
}

?></body></html>
