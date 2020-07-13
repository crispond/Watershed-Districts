<!DOCTYPE html>
<html><head><meta charset="utf-8"/><title>Watershed Districts</title></head><body>
<h1>Drawing Political Boundaries with Watersheds</h1>
Christopher B. Pond


<h3>Introduction</h3>
Gerrymandering is a problem which has risen into greater prominence recently, though it has been around since the early 19th century.  It's the process of intentionally drawing representational districts in order to facilitate a preferred outcome in democratic elections.  It can result in constituents being denied their Constitutional rights to fair and equal representation, and has been found in cases to intentionally disenfranchise racial minorities.  There are many ways to correct for this problem, and here I present one which I believe is novel, the creation of representational districts using watershed boundaries as a guide.


<h3>Definitions</h3>
<ul>
<li>Watershed:  A watershed is defined as a piece of territory where all water exits through a single point.  All land area can be broken down into these watersheds, each one emptying into another and forming the river systems of the Earth.</li>
<li>Parent/child:  The USGS Watershed Boundary Dataset contains geography definitions for watersheds in the USA, as well as a relationship between watersheds.  Water in a child watershed will flow into a parent watershed, and to designate this, the dataset contains a pointer from child to parent.  Several children can point to the same parent.  In this way, a tree-like structure can be defined which mirrors the flow of rivers.</li>
<li>Basin:  A basin is like a watershed, except that there is no entry point for water to flow in from other territory.</li>
<li>Closed basin:  Some basins do not flow to the sea.  In the case of a closed basin, water flows to a central point and simply evaporates.</li>
<li>District:  A geographical area containing a more-or-less equal distribution of population.  The US House of Representatives contains 435 seats, and the US population according to the 2010 census is 308,745,538 people, so each district should contain roughly 709,760 people.  In practise, the sizes of districts vary, since they are allocated state by state.</li>
<li>Census block:  A geographical area surveyed by the US Census Bureau to determine how many people live within it, among other things.  These are usually smaller than the watersheds supplied by the USGS.</li>
</ul>


<h3>Benefits</h3>
<ul><li>Little to no human interaction.  With no human interference, it's not possible to manipulate the drawing of district boundaries to facilite any particular political end.</li>
<li>Unlimited precision.  River systems are essentially a fractal geometry.  Each watershed can be theoretically divided into an infinite number of smaller watersheds, so any assignment definition can be applied as easily to sparsely-populated regions as to densely-populated urban areas.</li>
<li>Logical grouping.  Geographic boundaries like mountain ranges usually already demarcate human settlements, and settlements within valleys usually already have a cultural connexion to other settlements within that same valley.</li>
<li>Shared resources.  Water is a resource that everyone has in common.  We all require it for our survival, and we all draw water from the same sources.  If a representative of a district cannot site a source of pollution such that it flows downstream into someone else's district, it's much more likely she will take into account the needs of everyone affected by that pollution downstream.</li></ul>

<h3>Requirements</h3>
<ul><li>PostgreSQL, PostGIS, PL/pgSQL, GDAL and PHP</li>
<li>Table <a href = "ftp://rockyftp.cr.usgs.gov/vdelivery/Datasets/Staged/Hydrography/WBD/National/GDB/">wbdhu12</a> from the USGS Water Boundary Dataset</li>
<li><a href = "https://www2.census.gov/geo/tiger/TIGER2010BLKPOPHU/">Census data</a> for all states</li>
<li><a href = "https://catalog.data.gov/dataset/2016-cartographic-boundary-file-united-states-1-5000000">US borders</a> and <a href = "https://www.arcgis.com/home/item.html?id=e750071279bf450cbd510454a80f2e63">World Water Bodies</a></li>
<li><a href = "ftp://rockyftp.cr.usgs.gov/vdelivery/Datasets/Staged/Hydrography/NHD/National/HighResolution/GDB/">USGS National Hydrography data</a></li>
<li>Files WatershedDistricts.sql, include.php, basinconnector.php and trimtrees.php</li>
<li>Tested with Ubuntu 18.04 LTS, PHP 7.2, Postgres 10 and PostGIS 2.5.</li></ul>


<h3>Algorithm</h3>
<p>There are two main steps which need to be taken before a district map is created.  The first is the connexion of basins into a fully-hierarchical tree and the second is the division of that tree into related branches of equal size by population.</p>

<p>The philosophy for connecting the basins to one another is to disturb the descent channels as little as possible.  The way this is done is by determining which watersheds might connect two basins and for each pair of these watersheds, calculating a cost for making one basin the child of the other and vice versa.  These costs are essentially the distance between the root of a basin backwards against the flow of water to the boundary of the parent basin.  Additionally, any two watersheds which are both connected on the boundary are eliminated from the path calculation in the initial comparison.  This is to attempt to keep the descent reversals away from the center of the map.</p>

<p>Island groupings are connected at the point of closest approach, and the cost of connecting a watershed on one island to a watershed on another is merely the distance between the root of the basin, and the watershed in the same basin which is being connected.  This is because connecting the root to the parent basin would make many island connexions artificially expensive.  In the event that two island roots connect, connecting the smaller island to the larger one is considered less expensive.</p>

<p>The algorithm must order the basin connexions from least to most expensive, and as it connects each pair of basins, create a new pseudo-basin from the previous two.  On each new connexion, if an alteration of the child has taken place, the entire path from the root to the boundary must be reanalysed and if a larger penalty than the original is found, this connexion must use the new penalty and the connexion list must be reordered.</p>

<p>At the end of this process, the entire map should contain a single tree, which is optimised such that there is minimal traceback of descent channels.</p>

<p>The philosophy of the census block assignment is to use as many natural boundaries as possible and to draw artificial boundaries which are as short as possible.  To achieve this, it builds a district using an advancing edge of census blocks within a watershed branch.  To determine which branch in the tree should be used, a recursive and iterative process is employed.  First, the total population upstream is recorded for each watershed in the tree.  Then, the branch roots are identified which have a greater or equal population than the size of the district, and where each child has a population smaller than the size of the district.</p>

<p>Once the root watershed is found, the algorithm identifies all unassigned census blocks which lie within the watershed's branch.  It makes sure there are no stranded census blocks, makes sure there is enough contiguous space to assign a full district and begins assigning census blocks to the current district one by one.  For branch roots which do not lie on the border of the map, the next branch down which could contain another full district is identified, the farthest census block from this branch is identified and a perpendicular edge is created from this block to the target branch.  Blocks are added to this edge one by one until the district is complete.  As the district is filled, the edge rebalances itself to always remain perpendicular to the target branch.</p>

<p>For branch roots which end on a boundary, a two-stage process is employed.  In the first stage, the algorithm is the same as for non-boundary territory, but using the existing branch root instead of the next root containing another full district.  If at any point in the block assignment a block touches the boundary the algorithm switches the edge from being perpendicular to the target to being perpendicular to the border of the map.  Once this first stage is completed, a second stage begins where the starting block is the farthest block away along the map border instead of being the farthest block away from the branch root.  This phase also uses the next branch down which could contain another full district as a target.  Blocks are assigned on the edge perpendicular to the map boundary until the population target is reached.  The final edge of the resulting district is compared with the edge in the first phase and the district with the shortest edge is selected.</p>

<p>For all block assignments, whenever the edge changes its angle, it pivots in order that the artificial boundary should always remain straight.  This should always result in the shortest possible artificial boundary.</p>

<p>As each district is assigned, the available population in each watershed branch root is reduced.  Multiple passes are made from the global root until there is no more territory left to assign.</p>


<h3>Caveats</h3>
<ul><li>Humans may be able to intentionally change the topography in order to connect watersheds that were once separate.  The reason it is unlikely that anyone would do this is because the algorithm usually groups watersheds with neighbouring watersheds.  Very little advantage is likely to be gained by artificially connecting watersheds that were once unconnected.  Additionally, the farther apart in the tree the watersheds are, the larger the geographical boundary between them, and the greater the expense.  It's unlikely the cost would be worth the reward.</li>
<li>Water will still flow from one district to another.  There are over 75 million people living in the Mississippi River basin in the USA alone.  That's far too many to fit into a single district the way the US government is currently structured, so districts must flow from one to another out of necessity.  One creative solution to this problem might be establishing a variable multi-member district system based on river basin, though in the Mississippi basin, this would result in a single district represented by over 100 members.  This could cause practical problems in a multi-member election system.  A compromise solution might be to break each basin down into a series of smaller groupings.</li>
<li>Much of the distance calculation in the algorithm is Cartesian.  This is a fine approximation for relative comparision of short distances, but can radically change the output for very long distances.  For example, the closest approach of the Hawaiian archipelago to the remainder of US territory is the Aleutian islands, but if the calculation is made with a Mercator spherical projection, the closest approach is determined to be Southern California.  Great circle geographical distance calculation is the gold standard, but can be processor-intensive.  The island connexion code which uses great circle measurement requires several hours of processing time.</li></ul>


<h3>Conclusion</h3>
This approach, in whole or in part, could have significant advantages over current methods of determining representational districts, both in terms of fairness, and in terms of human and financial resources required to generate the maps and litigate the outcome.  It should be evaluated as to whether in practise it would result in districts which would give constituents their Constitutionally guaranteed right to democratic representation.

</body></html>
