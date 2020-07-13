/*

Watershed Districts 3.1

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

-------------------------------------------------
Sections
	 1.  Notes
	 2.  Required Functions
	 3.  Import Base Data (5 hr)
	 4.  Clean and Snap Watershed Geometries (13 hr)
	 5.  Chop by Political Boundary (1.5 hr)
	 6.  Create Watershed Adjacency Network (2 hr)
	 7.  Set Watershed Attributes (7 hr)
	 8.  Connect Non-Contiguous Polygon Groups (7.5 hr for state-agnostic. 13 min for traditional.)
	 9.  Process Census Data (13.5 hr)
	10.  PHP processing (5 hr)
	11. Data export and post-processing (5 min)
-------------------------------------------------
*/


----------
--1. Notes
----------
--These statements should not be run as a batch, because they sometimes rely heavily on indices which are not known to the query planner in advance.
--When in doubt, use PGScript, or break up execution into smaller pieces.  It might be a good idea to stage process based on section and run consistency tests after each.
--PGScript is required for much of the processing.  The importation requires GDAL.
--Maximise memory for all temporary tables.
set temp_buffers = '8GB';


-----------------------
--2. Required Functions
-----------------------
--The mortoncode and mercatorcoordinates functions are only used in the creation of wdcensusstates.
--raisenotice is used throughout, but only to track progress.

--Raises notice in order to check progress in batch files
CREATE OR REPLACE FUNCTION raisenotice(_noticetext text default null)
	RETURNS boolean AS
$BODY$
begin
	raise notice '%', _noticetext;
	return true;
end; $BODY$
LANGUAGE 'plpgsql' immutable;

--Takes r, and floating point values for x and y and returns index of spherical mercator tile that contains the point.
--drop function if exists mercatorcoordinates(integer, double precision, double precision, integer);
create or replace function mercatorcoordinates (_r int, _x float, _y float, _srid int default 3857, out x int, out y int) as $$
	declare _thegeom geometry; _xtranslated float; _ytranslated float; _mapwidth float := 40075016.6855785;
begin
	--Eliminate nulls
	if _r is null then
		_r := 0;
	end if;
	if _x is null then
		_x := 0;
	end if;
	if _y is null then
		_y := 0;
	end if;
	--Projection will fail with latitudes close to 90/-90.  Correct to +\- 89.
	if _srid = 4326 and abs(_y) > 89 then
		_y := 89.0 * _y / abs(_y);
	end if;
	_thegeom := st_transform (st_setsrid (st_makepoint(_x, _y), _srid), 3857);
	_xtranslated:= st_x(_thegeom);
	_ytranslated:= st_y(_thegeom);
	if abs(_xtranslated) > (_mapwidth / 2) then
		_xtranslated := _mapwidth / 2 * (_xtranslated / abs(_xtranslated));
	end if;
	if abs(_ytranslated) > (_mapwidth / 2) then
		_ytranslated := _mapwidth / 2 * (_ytranslated / abs(_ytranslated));
	end if;
	x := floor ((_xtranslated + _mapwidth / 2) * (1 << _r) / _mapwidth);
	y := floor ((_mapwidth / 2 - _ytranslated) * (1 << _r) / _mapwidth);
	if x < 0 then
		x := 0;
	elsif x >= (1 << _r) then
		x := (1 << _r) - 1;
	end if;
	if y < 0 then
		y := 0;
	elsif y >= (1 << _r) then
		y := (1 << _r) - 1;
	end if;
end;
$$ LANGUAGE plpgsql immutable;

--Morton code.  Bitwise-interleaved x/y values for closest approach functions.
create or replace function mortoncode (_x int4 default 0, _y int4 default 0)
returns int8 as $$
	declare _m int8 = 0; _i int2 = 0;
begin
	--Negative values are not allowed.  Proper code should use unsigned integers.
	if _x < 0 or _x is null then
		_x := 0;
	end if;
	if _y < 0 or _y is null then
		_y := 0;
	end if;
	while _x > 0 or _y > 0 loop
		_m := _m | ((_x & 1)::int8 << (_i * 2 + 1)) | ((_y & 1)::int8 << (_i * 2));
		_i := _i + 1;
		_x := _x >> 1;
		_y := _y >> 1;
	end loop;
	return (_m);
end;
$$ language plpgsql immutable;


---------------------
--3. Import Base Data
---------------------
--Tables required: wbdhu12, tabblock2010_xx_pophu (multiple), wdcensusstates, nhdflowline, nhdwaterbody, cb_2016_us_nation_5m, and/or wdwaterv106

--wbdhu12: High-resolution watershed boundaries from USGS.  Publish date: 2019-06-28.
--Source: ftp://rockyftp.cr.usgs.gov/vdelivery/Datasets/Staged/Hydrography/WBD/National/GDB/WBD_National_GDB.zip
--Other tables appear to be more detailed, but not complete.  wbdhu14 is just part of Alaska, and wbdhu16 is empty. wbdhu12 has duplicate huc-value, as does wbdhu14.  All other hucs are unique.
--Lists tables: ogrinfo WBD_National_GDB.zip
--Imports into PostGIS.  Be sure file permissions allow postgres to read files. Tested with GDAL 2.2.3.  Make sure postgres account has full access to files.
--sudo -u postgres ogr2ogr -f PostgreSQL PG:"dbname=db user=postgres" WBD_National_GDB.zip WBDHU12 -nlt CONVERT_TO_LINEAR
--Alternative: ogr2ogr -f PGDump out.dump WBD_National_GDB.zip WBDHU12 --config PG_USE_COPY YES -nlt CONVERT_TO_LINEAR && psql --username=postgres --dbname=db < out.dump
--Clean up watershed geometries.  Tree needs to be altered, and geometries need to be snapped together, simplified, and holes need to be removed.
--Create nicer primary key, and set up parent pointer for tree.
alter table wbdhu12 rename objectid to id; alter table wbdhu12 add parentid int;
alter table wbdhu12 add mercgeom geometry(multipolygon, 3857); alter table wbdhu12 alter column mercgeom set storage external;
update wbdhu12 set mercgeom = st_transform(wkb_geometry, 3857); create index ix_wbdhu12_mercgeom on wbdhu12 using gist(mercgeom);
--This import seems to require a vacuum afterward: vacuum full verbose analyze wbdhu12;
--There are some descent errors in the source data.
--Moosehead Lake, ME is actually a composite watershed!  It has 2 outflows.  To make it exit at "Indian Pond", run this.
--update wbdhu12 set tohuc = '010300010603' where huc12 = '010300010510';
--These are unambiguous errors.
update wbdhu12 set tohuc = '190103031109' where huc12 = '190103031108';
update wbdhu12 set tohuc = '041503100402' where huc12 in ('041503040502', '041503050706');
--Cleaning up non-unique huc12 values for proper tree descent.  The few errors stem from 2 least-significant digits being zeroed-out:
drop table if exists _swap; create temp table _swap (id serial, wsid int);
insert into _swap (wsid) select a.id from wbdhu12 a inner join (select huc12, count(*) from wbdhu12 group by huc12 having count(*) > 1) b on a.huc12 = b.huc12;
update wbdhu12 b set huc12 = substring (huc12, 1, 10) || (99 - a.id)::varchar from _swap a where a.wsid = b.id;
--These guys are exit points: 'MEXICO','OCEAN','CANADA','CLOSED BASIN'... They are not always reliable.
--Some parents are circular:
update wbdhu12 a set parentid = b.id from wbdhu12 b where a.tohuc = b.huc12 and a.tohuc != a.huc12;
/*
--Creates original river structure:
drop table if exists wdrivers; select c.id, c.parentid, st_makeline(st_centroid(c.mercgeom), st_centroid(d.mercgeom)) as mercgeom into wdrivers from
wbdhu12 c inner join wbdhu12 d on c.parentid = d.id;
*/

--tabblock2010_xx_pophu/wdcensusblocks: Census geometries, 2010: multiple state files accumulated from https://www2.census.gov/geo/tiger/TIGER2010BLKPOPHU/
--This extracts and imports all census shapefiles.  Run as postgres:
select 'wget https://www2.census.gov/geo/tiger/TIGER2010BLKPOPHU/tabblock2010_' || lpad (stateid::varchar, 2, '0')
	|| '_pophu.zip && 7z e tabblock2010_' || lpad (stateid::varchar, 2, '0') || '_pophu.zip && shp2pgsql -D tabblock2010_'
	|| lpad (stateid::varchar, 2, '0') || '_pophu | psql -d db && rm tabblock2010_' || lpad (stateid::varchar, 2, '0') || '_pophu*' as commandline,
	'select sum(pop10) as pop10 from tabblock2010_' || lpad (stateid::varchar, 2, '0') || '_pophu union all' as totalpopulation,
	'select blockid10, statefp10::int as stateid, pop10 as population, st_transform(st_setsrid(geom, 4269), 3857)::geometry(multipolygon, 3857) as mercgeom from tabblock2010_' || lpad (stateid::varchar, 2, '0') || '_pophu union all' as mergedata,
	'drop table if exists tabblock2010_' || lpad (stateid::varchar, 2, '0') || '_pophu;' as cleanup
from (select generate_series(1, 56) stateid) a where stateid not in (3, 7, 14, 43, 52);
--Merge into single giant table.  blockid10 is unique:
drop table if exists wdcensusblocks; create table wdcensusblocks (id serial primary key, blockid10 varchar, stateid int, population int, islandid int, boundary boolean, mercgeom geometry(multipolygon, 3857));
alter table wdcensusblocks alter column mercgeom set storage external;
--insert into wdcensusblocks (blockid10, stateid, population, mercgeom) ... order by 1;
--Translate census blocks which pass over IDL:
update wdcensusblocks set mercgeom = st_translate (mercgeom, -pi() * 2.0 * 6378137.0, 0) where st_x(st_centroid(mercgeom)) > 0;
--Index census blocks.
create index ix_wdcensusblocks_mercgeom on wdcensusblocks using gist(mercgeom);

--wdcensusstates:  State geometries or national geometry built from census blocks, including FIPS code, name, population and representatives.
--FIPS code and name: http://www2.census.gov/geo/docs/maps-data/data/geo_tallies/census_block_tally.txt
--Results of 2010 apportionment: https://sourceforge.net/p/watershed-districts/code/HEAD/tree/SourceData/ApportionmentPopulation2010.csv?format=raw
--(For reference, original 2010 apportionment source is here: https://www2.census.gov/programs-surveys/decennial/2010/data/apportionment/ApportionmentPopulation2010.xls )
drop table if exists _states; create temp table _states (stateid int, mortoncode bigint, population int, mercgeom geometry(multipolygon, 3857)); alter table _states alter column mercgeom set storage external;
drop table if exists _censusblocktally; create temp table _censusblocktally (FIPSStateCode text, Name text, Numberof2010CensusBlocks text, Numberof2000CensusBlocks text, NumericalChange20002010 text, PercentChange20002010 text);
drop table if exists _staterepresentatives; create temp table _staterepresentatives (state varchar, population varchar, representatives int);
/*
--Instead of populating operational table with state-specific watersheds, it's also possible to create a single, national dataset.
--This can be helpful in determining what the map would look like with a fairer population distribution
--and to see what the real boundaries would look like absent state borders crossing natural boundaries.
--Back up stateid and set all blocks to a pseudo-state of 1, then add pseudo-state to census block tally (name-ID definition)
--and add total number of reps to state representatives table, currently 435 total in the USA. ~30 minutes.
alter table wdcensusblocks add originalstateid int; update wdcensusblocks set originalstateid = stateid, stateid = 1;
alter table _censusblocktally add stateid int; insert into _censusblocktally (name, stateid) values ('USA', 1);
insert into _staterepresentatives (state, population, representatives) select 'USA', (select sum(population) from wdcensusblocks), 435;
*/
--This batch calculates traditional state districts.  Don't run this block if generating state-agnostic districts.
copy _censusblocktally from '/tmp/census_block_tally.txt'; alter table _censusblocktally add stateid int;
update _censusblocktally set stateid = substring (FIPSStateCode, '[0-9]+')::int, name = trim(name); delete from _censusblocktally where stateid is null;
copy _staterepresentatives from '/tmp/ApportionmentPopulation2010.csv' with CSV header; delete from _staterepresentatives where representatives is null;
--Taxation without representation for DC... but add anyway, to avoid division by zero.
insert into _staterepresentatives (state, population, representatives) select a.name, sum(b.population), 1
from _censusblocktally a inner join wdcensusblocks b on a.stateid = b.stateid where a.name in ('District of Columbia') group by 1, 3;
--Generates states using census geometries.  Requires mercatorcoordinates and mortoncode functions.
--It's possible to do it without PGScript and the helper functions, but it's much slower.  This took 5:14 hours:
--drop table if exists wdcensusstates; select stateid, sum(population) as population, st_unaryunion(st_collect(mercgeom)) as mercgeom into wdcensusstates from wdcensusblocks group by 1 order by 1;
--The timing for stepping the merge in hours: dr = 1: 2:22. dr = 2: 2:06. dr = 3: 2:02. dr = 4: 2:02. dr = 5: 2:05. dr = 6: 2:10. dr = 7: 2:22
--The sweet spot seems to be around 3 or 4.  It's probably dependent on memory.
--Begin creating merged geometries starting with tiles at r13 and decreasing by supplied step. Stop when either r is 0 or all geometries are in single tile.
set @r = 13; set @step = 3;
insert into _states select stateid, mortoncode(x(gc), y(gc)) as mortoncode, population, mercgeom from (
	select stateid, mercatorcoordinates(@r, st_x(st_centroid(mercgeom)), st_y(st_centroid(mercgeom))) as gc, population, mercgeom from wdcensusblocks
) a order by 1,2;
while @r >= 0 begin
	select raisenotice(now()::text || ' - R' || @r);
	--Merge into swap table. 10r-direct lasts 1:34:00
	drop table if exists _swap; create temp table _swap (stateid int, mortoncode bigint, population int, mercgeom geometry(multipolygon, 3857)); alter table _swap alter column mercgeom set storage external;
	insert into _swap select stateid, mortoncode, sum(population)::int as population, st_multi(st_unaryunion(st_collect(mercgeom))) as mercgeom from _states group by 1,2 order by 1,2;
	--Back-populate and back up step levels
	drop table if exists _states; create temp table _states (stateid int, mortoncode bigint, population int, mercgeom geometry(multipolygon, 3857)); alter table _states alter column mercgeom set storage external;
	insert into _states select stateid, mortoncode >> (2 * @step) as mortoncode, population, mercgeom from _swap order by stateid, mortoncode;
	--Stop if everything's already in the same tile
	if (select 1 where (select count(distinct mortoncode) from _swap) = 1) begin
		set @r = -1;
	--If the next value will be less than zero, set it to zero
	end else if @step > @r and @r > 0 begin
		set @r = 0;
	end else begin
		set @r = @r - @step;
	end
end
--Create permanent state table with single geometry for each state.  In a national map, this will merge states together.
drop table if exists wdcensusstates; create table wdcensusstates (stateid int, population int, representatives int, name varchar, mercgeom geometry(multipolygon, 3857)); alter table wdcensusstates alter column mercgeom set storage external;
insert into wdcensusstates (stateid, population, representatives, name, mercgeom) select a.stateid, a.population, c.representatives, b.name::varchar, a.mercgeom
from _states a inner join _censusblocktally b on a.stateid = b.stateid inner join _staterepresentatives c on b.name = c.state order by 1;
create index ix_wdcensusstates_mercgeom on wdcensusstates using gist(mercgeom);

--nhdflowline:  River geometries to calculate exit point of each watershed into another watershed or off the map boundary.
--ftp://rockyftp.cr.usgs.gov/vdelivery/Datasets/Staged/Hydrography/NHD/National/HighResolution/GDB/NHD_H_National_GDB.zip
--These are fairly large files for 2020.  They may import faster if they are unzipped first.
--7z x NHD_H_National_GDB.zip
--sudo -u postgres ogr2ogr -f "PostgreSQL" PG:"dbname=db user=postgres" NHD_H_National_GDB.gdb NHDFlowline -nlt CONVERT_TO_LINEAR -dim XY

--nhdwaterbody:  Lake and evaporation playa polygons to calculate approximate evaporation point of closed basin. Same source as nhdflowline.
--sudo -u postgres ogr2ogr -f "PostgreSQL" PG:"dbname=db user=postgres" NHD_H_National_GDB.gdb NHDWaterbody -nlt CONVERT_TO_LINEAR -dim XY

--cb_2016_us_nation_5m: USA boundary file from https://www2.census.gov/geo/tiger/GENZ2016/shp/cb_2016_us_nation_5m.zip
--7z x cb_2016_us_nation_5m.zip && shp2pgsql -D cb_2016_us_nation_5m |sudo -u postgres psql -d db

--wdwaterv106: This is a more detailed oceans file to separate the shore from the sea in the watershed dataset. https://www.arcgis.com/home/item.html?id=e750071279bf450cbd510454a80f2e63
--7z x World_Water_Bodies.lpk; cd v106/; ogrinfo hydropolys.gdb; sudo find . -type d -print0 | sudo xargs -0 chmod 777; sudo find . -type f -print0 | sudo xargs -0 chmod 777
--sudo -u postgres ogr2ogr -f "PostgreSQL" PG:"dbname=db user=postgres" hydropolys.gdb -nln wdwaterv106
--Vacuum afterward, JIC: vacuum full verbose analyze wdwaterv106;


----------------------------------------
--4. Clean and Snap Watershed Geometries
----------------------------------------
--Running st_simplify on polygons that border other polygons introduces too much noise and causes cascading point collapses when you try to snap the faces back together.
--An alternative to this might be to do a one-way simplify of a contiguous 2-polygon border region, and then match the whole thing back together, but first, all space between polygons must be eliminated.
--Dumping the geometries creates polygons from multipolygons.  Ringing them removes holes. These "rings" must have more than 3 points, or they can't be made back into polygons.
--Many of the resulting geometries will self-intersect, so they need to be made valid.  This, again, introduces holes and creates multipolygons,
--so the whole thing must be dumped and ringed again, and at the very end forced to obey the right-hand rule.
--This should get you a table of valid, single polygons with no holes which all proceed clockwise.
--I believe I could do this with one massive, embedded query, but it seems to proceed slightly faster with an interim table...
select raisenotice(now()::text || ' - Clean and Snap Watershed Geometries.');
drop table if exists _stage2; select id as externalid, st_removerepeatedpoints(st_exteriorring(geom(st_dump(mercgeom)))) as mercgeom
into temp _stage2 from wbdhu12;

--This baseline should be valid, simple polygons.  Just snapping the geometries together is so labour-intensive, it's better to establish a baseline first.
drop table if exists wdwsbaseline; create table wdwsbaseline (id serial primary key, externalid int, mercgeom geometry(polygon, 3857));
alter table wdwsbaseline alter column mercgeom set storage external;
insert into wdwsbaseline (externalid, mercgeom) select externalid, st_forcerhr(st_makepolygon(st_exteriorring(geom(st_dump(st_makevalid(st_makepolygon(
	mercgeom
))))))) from _stage2 where st_npoints(mercgeom) > 3 order by 1;

--Tweak the watersheds which cross the IDL.
update wdwsbaseline set mercgeom = st_translate (mercgeom, -pi() * 2.0 * 6378137.0, 0) where st_x(st_centroid(mercgeom)) > 0;
create index ix_wdwsbaseline_mercgeom on wdwsbaseline using gist (mercgeom);

--The st_within below removes all island detail if there's a single water polygon around the island. This is a problem for the Door "Peninsula"
--in Wisconsin, some of the Hawaiian islands, and a few more cases, but only Hawai'i has a population large enough to make it a problem.
--In the original source data, find simple polygons which have negative space.
drop table if exists _negativespace; create temp table _negativespace (id serial primary key, externalid int, mercgeom geometry(polygon, 3857)); alter table _negativespace alter column mercgeom set storage external;
insert into _negativespace (externalid, mercgeom) select id, st_makepolygon(st_exteriorring(mercgeom))
from (select id, geom(st_dump(mercgeom)) as mercgeom from wbdhu12 where st_nrings(mercgeom) > 1) a where st_nrings(mercgeom) > 1 order by 1;

--Remove problematic ring geometries from around islands.
delete from wdwsbaseline a using (
	--Within the outer shells of these simple negative polygons, there is more than one other polygon.
	select a.id, a.externalid from _negativespace a inner join wbdhu12 b on st_within(b.mercgeom, a.mercgeom)
		and a.externalid != b.id group by 1,2 having count(distinct b.id) > 1
) b where a.externalid = b.externalid
--Just eliminate Hawaiian rings
and a.mercgeom && 'POLYGON ((-18023163.402875673 1993605.0404536496,-18023163.402875673 2699289.711162052,-17040503.520114485 2699289.711162052,-17040503.520114485 1993605.0404536496,-18023163.402875673 1993605.0404536496))'::geometry;

--Get rid of anything that's completely encapsulated
delete from wdwsbaseline a using wdwsbaseline b where st_within(a.mercgeom, b.mercgeom) and a.id != b.id;

--The following is code to perfectly-align polygons with one-another.  The district grouping algorithm requires that there be no space between polygons.
--If your disk is slow to write, this can take up to 20 hours!  This MAY be an issue with MS Postgres.  A linux installation is significantly faster.
--The snap portion will grab nearby points to the polygon, and snap the ring to those points.
--If you just want to skip this step, it can be avoided and the loop only run once, but the shapes will move around much more.
--PGScript:
set @pass = 1;
while @pass < 3 begin
	select raisenotice(now()::text || ' - Begin pass @pass.');

	--Try snapping new points from base. On Microsoft Postgres installations, this is significantly slower (2-5 hours per block!)
	--Each block should take no more than 20 minutes.
	drop table if exists _points; create temp table _points (id serial primary key, wsid int, ordinal int, ordinal1 int, x double precision, y double precision, mercgeom geometry(point));
	insert into _points (wsid, ordinal, ordinal1, x, y, mercgeom)
	select id, (path(thedump))[2] as ordinal, (path(thedump))[2] + 1 as ordinal1, st_x(geom(thedump)), st_y(geom(thedump)), geom(thedump)
	from (select id, st_dumppoints(mercgeom) as thedump from wdwsbaseline) a order by 4, 5, 1, 2;
	create unique index ix__points_wsid_ordinal on _points using btree(wsid, ordinal);
	select raisenotice(now()::text || ' - Done points.');

	--Create segments from points.
	drop table if exists _segments;
	create temp table _segments (id serial, wsid int, ordinal int, x0 double precision, y0 double precision, x1 double precision, y1 double precision, mercgeom geometry(linestring));
	insert into _segments (wsid, ordinal, x0, y0, x1, y1, mercgeom) select a.wsid, a.ordinal, a.x, a.y, b.x, b.y, st_makeline(a.mercgeom, b.mercgeom)
	from (select wsid, ordinal, ordinal1, x, y, mercgeom from _points order by wsid, ordinal1) a
	inner join (select wsid, ordinal, x, y, mercgeom from _points order by wsid, ordinal) b on a.wsid = b.wsid and a.ordinal1 = b.ordinal
	order by 3, 4, 5, 6, 1, 2;
	drop table if exists wdwssegments; select * into wdwssegments from _segments; alter table wdwssegments add primary key (id);
	create unique index ix_wdwssegments_wsid_ordinal on wdwssegments using btree(wsid, ordinal);
	select raisenotice(now()::text || ' - Done segments.');

	--The query optimiser is less than perfect here.  If you add a sort condition to the query, it will use the order on disk... 12 minutes.
	drop table if exists wdunconnectedsegments; create table wdunconnectedsegments (id int primary key, wsid int, ordinal int,
		x0 double precision, y0 double precision, x1 double precision, y1 double precision, mercgeom geometry(linestring));
	insert into wdunconnectedsegments
	select a.* from (select * from wdwssegments order by x0, y0, x1, y1) a
	left join (select * from wdwssegments order by x1, y1, x0, y0) b
		on a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0 and a.wsid != b.wsid
	where st_length(a.mercgeom) > 0 and b.id is null order by a.id;
	create index ix_wdunconnectedsegments_mercgeom on wdunconnectedsegments using gist(mercgeom);
	create unique index ix_wdunconnectedsegments_wsid_ordinal on wdunconnectedsegments using btree(wsid, ordinal);
	select raisenotice(now()::text || ' - Done unconnected segments.');

	--Adding points from segments:
	--You need to force an order on x/y here!  If you don't, the scheduler will not optimise correctly.
	--Explain should NEVER give you a hash.  It should always give you a sort. 10 minutes.
	drop table if exists wdunconnectedpoints; create table wdunconnectedpoints (id int primary key, wsid int, ordinal int,
		x double precision, y double precision, mercgeom geometry(point));
	insert into wdunconnectedpoints select b.* from (
		select x0 as x, y0 as y from wdunconnectedsegments union select x1, y1 from wdunconnectedsegments order by 1, 2	
	) a inner join (select id, wsid, ordinal, x, y, mercgeom from _points order by x, y) b on a.x = b.x and a.y = b.y order by 1;
	create index ix_wdunconnectedpoints_mercgeom on wdunconnectedpoints using gist(mercgeom);
	create unique index ix_wdunconnectedpoints_wsid_ordinal on wdunconnectedpoints using btree(wsid, ordinal);
	select raisenotice(now()::text || ' - Done unconnected points.');

	--Snap portion. Only run on the first pass
	if @pass = 1 begin
		--Snapping polygons to nearby points.  For inclusion, point must be less than 2 meters from a segment and more than 8 meters from both endpoints.
		--This seems to work very well!  It only appears to introduce minor errors. 17 minutes:
		drop table if exists _snaps;
		select a.wsid, a.externalid, st_forcerhr(st_makepolygon(st_exteriorring(a.mercgeom))) as mercgeom into temp _snaps from (
			select a.wsid, b.externalid, geom(st_dump(st_makevalid(st_makepolygon(st_snap(st_exteriorring(b.mercgeom), st_setsrid(a.mercgeom, 3857), 2))))) as mercgeom from
			(
				select a.wsid, st_collect(mercgeom) as mercgeom from (
					select a.wsid, null::int as ordinal, b.mercgeom from wdunconnectedsegments a, wdunconnectedpoints b
					where st_dwithin(a.mercgeom, b.mercgeom, 2) and a.wsid != b.wsid
					and st_distance(st_startpoint(a.mercgeom), b.mercgeom) > 8 and st_distance(st_endpoint(a.mercgeom), b.mercgeom) > 8
					union all select b.wsid, b.ordinal, b.mercgeom from (select distinct wsid as wsid from wdunconnectedpoints order by wsid) a
					inner join (select * from _points order by wsid, ordinal) b on a.wsid = b.wsid order by 1, 2
				) a group by a.wsid order by a.wsid
			) a inner join wdwsbaseline b on a.wsid = b.id order by b.id
		) a where st_geometrytype(a.mercgeom) = 'ST_Polygon' order by a.wsid;
		--Add new geometries back in:
		insert into wdwsbaseline (externalid, mercgeom) select externalid, mercgeom from _snaps order by wsid;
		--Delete old geometries:
		delete from wdwsbaseline a using _snaps b where a.id = b.wsid;
		--Get rid of anything that's completely encapsulated:
		delete from wdwsbaseline a using wdwsbaseline b where st_within(a.mercgeom, b.mercgeom) and a.id != b.id;
		select raisenotice(now()::text || ' - Done snap.');
	end
	set @pass = @pass + 1;

end

--It does need this index for the following query.  It's fairly labour-intensive.
create index ix_wdwssegments_mercgeom on wdwssegments using gist(mercgeom);

--Generate nearby segments
drop table if exists wdnearbysegments; create table wdnearbysegments (id int primary key, wsid int, ordinal int,
	x0 double precision, y0 double precision, x1 double precision, y1 double precision, mercgeom geometry(linestring));
insert into wdnearbysegments select * from wdunconnectedsegments order by id;
create index ix_wdnearbysegments_mercgeom on wdnearbysegments using gist(mercgeom);

--Generate holding pen for finished points and segments:
drop table if exists wdfinishedpoints; select * into wdfinishedpoints from wdunconnectedpoints where 0=1;
drop table if exists wdboundarypoints; select * into wdboundarypoints from wdunconnectedpoints where 0=1;
drop table if exists wdfinishedsegments; select * into wdfinishedsegments from wdunconnectedsegments where 0=1;
drop table if exists wdboundarysegments; select * into wdboundarysegments from wdunconnectedsegments where 0=1;

--Primary loop to collapse gaps between polygons and establish boundary.  It will proceed until there are no more unconnected segments and no more intersections.
--Set pass and tolerance
set @pass = 1;
set @maxtolerance = 8;
--Prime intersection table.  Assume there are none to start with.
drop table if exists _segmentintersections; select 1 as id into temp _segmentintersections where 0=1;
while (select 1 from wdunconnectedsegments limit 1) or (select 1 from _segmentintersections limit 1) begin
	select raisenotice('Pass: @pass');
	--If a boundary has been populated, and there are still unconnected segments, set tolerance for largest segment.
	if (select 1 from wdboundarysegments limit 1) and (select 1 from wdunconnectedsegments limit 1) begin
		set @maxtolerance = (select max(st_length(mercgeom) + 1) from wdunconnectedsegments); set @maxtolerance = @maxtolerance[0][0] + 1;
		select raisenotice('Maximum tolerance: @maxtolerance');
	end
	--Create ties table which ties each point pair with one-another:
	drop table if exists _ties; create temp table _ties (id serial primary key, x0 double precision, y0 double precision,
		x1 double precision, y1 double precision, mercgeom geometry(point, 3857));
	--Prepare table of unique points to be moved.  They should be unique by x/y.
	drop table if exists _movedpoints; create temp table _movedpoints (id serial primary key, tieid int, x double precision, y double precision, mercgeom geometry(point, 3857));
	--If this is the first pass, calculate closest candidates among unconnected points.
	--Also calculate closest candidates if the boundary has been populated, and there are still some unconnected segments left.
	if (@pass = 1 or ((select 1 from wdboundarysegments limit 1) and (select 1 from wdunconnectedsegments limit 1))) begin
		select raisenotice(now()::text || ' - Calculating closest points.');
		--Generate ties, then grab anyone with range of the centerpoints of those ties, then correct segments within merge range of each other.
		--I THINK you can always collapse a closest approach between points on the same polygon, as long as there is no intersection,
		--and as long as both points point to at least one 3rd point which you include in the merge...
		drop table if exists _candidatematches; create temp table _candidatematches (id serial primary key,
			x0 double precision, y0 double precision, x1 double precision, y1 double precision, thedistance double precision);
		insert into _candidatematches(x0, y0, x1, y1, thedistance) select distinct a.x as x0, a.y as y0, b.x as x1, b.y as y1,
			st_distance(a.mercgeom, b.mercgeom) as thedistance
		from wdunconnectedpoints a inner join wdunconnectedpoints b on st_dwithin(a.mercgeom, b.mercgeom, @maxtolerance) and a.wsid != b.wsid
		and st_distance(a.mercgeom, b.mercgeom) > 0 order by a.x, a.y, b.x, b.y;
		--Add the closest approach for each point.  x0, y0 is the point being examined.
		insert into _ties (x0, y0, x1, y1, mercgeom) select a.*, st_setsrid(st_centroid(st_collect(st_makepoint(a.x0, a.y0), st_makepoint(a.x1, a.y1))), 3857) as mercgeom
		from (
			select distinct x0, y0,
			first_value(x1) over (partition by x0, y0 order by thedistance, id) as x1,
			first_value(y1) over (partition by x0, y0 order by thedistance, id) as y1 from _candidatematches
		) a order by 1,2,3,4;
		--The closest neighbour of one point does not always have that point as a closest neighbour. Delete the non-reciprocal closest approaches:
		delete from _ties a using _ties b left join _ties c on b.x0 = c.x1 and b.y0 = c.y1 and b.x1 = c.x0 and b.y1 = c.y0 where a.id = b.id and c.id is null;
		--Only have one connexion per tie!
		delete from _ties where x0 > x1 or (x0 = x1 and y0 > y1);
		--On first pass, grab anyone within range of the tie centerpoint.  This should ensure a proper seal on the boundary.
		if @pass = 1 begin
			select raisenotice(now()::text || ' - First pass greedy point collection.');
			--This table contains points within range of center, not another existing point.  It should be unique by tieid/x/y.
			drop table if exists _tieconnections; select a.id as tieid, b.id as pointid, st_distance (a.mercgeom, b.mercgeom) as thedistance into temp _tieconnections
			from _ties a inner join wdunconnectedpoints b on st_dwithin(a.mercgeom, b.mercgeom, @maxtolerance);
			--Populate moved points, connecting each point to closest tie. Should now be unique by x/y.
			insert into _movedpoints (tieid, x, y, mercgeom) select a.tieid, a.x, a.y, st_setsrid(st_makepoint(a.x, a.y), 3857) from (
				select distinct a.tieid, b.x, b.y from (
					select distinct pointid, first_value(tieid) over (partition by pointid order by thedistance, pointid) as tieid from _tieconnections
				) a inner join wdunconnectedpoints b on a.pointid = b.id order by 2, 3
			) a;
			
		end else begin
			select raisenotice(now()::text || ' - Closing gaps after outer boundary has been generated.');
			--If it's a standard cycle closing internal gaps, just add unique x/y values for each tie to moved points.
			insert into _movedpoints (tieid, x, y, mercgeom)
			select a.tieid, a.x, a.y, st_setsrid(st_makepoint(a.x, a.y), 3857) from (
				select id as tieid, x0 as x, y0 as y from _ties union select id, x1, y1 from _ties order by 2, 3
			) a;
		end
	--This is not the first pass, and the boundary has not yet been calculated.  Remove all intersections.
	end else begin
		select raisenotice(now()::text || ' - Removing segment intersections.');
		--This table finds all segments which come very close to one another, but have no endpoints in common.
		--The tolerance is required, because sometimes st_intersects returns different results depending on order when segments are very close.
		drop table if exists _segmentintersections; select st_collect(a.mercgeom, b.mercgeom) as mercgeom, a.id as aid, b.id as bid into temp _segmentintersections
		from wdnearbysegments a, wdnearbysegments b where a.id != b.id and st_dwithin(a.mercgeom, b.mercgeom, 0.00001)
		and not st_intersects(st_startpoint(a.mercgeom), st_startpoint(b.mercgeom)) and not st_intersects(st_startpoint(a.mercgeom), st_endpoint(b.mercgeom))
		and not st_intersects(st_endpoint(a.mercgeom), st_startpoint(b.mercgeom)) and not st_intersects(st_endpoint(a.mercgeom), st_endpoint(b.mercgeom));
		--Select closest 2 endpoints for each intersecting segment.
		drop table if exists _closestintersectionpoints;
		select distinct st_x(mercgeom0) as x0, st_y(mercgeom0) as y0, st_x(mercgeom1) as x1, st_y(mercgeom1) as y1 into temp _closestintersectionpoints from (
			select first_value(a.mercgeom) over (partition by a.aid, a.bid order by st_distance(a.mercgeom, b.mercgeom)) as mercgeom0,
				first_value(b.mercgeom) over (partition by a.aid, a.bid order by st_distance(a.mercgeom, b.mercgeom)) as mercgeom1
			from (
				select st_startpoint(b.mercgeom) as mercgeom, a.aid, a.bid from _segmentintersections a inner join wdnearbysegments b on a.aid = b.id union all
				select st_endpoint(b.mercgeom) as mercgeom, a.aid, a.bid from _segmentintersections a inner join wdnearbysegments b on a.aid = b.id
			) a inner join (
				select st_startpoint(b.mercgeom) as mercgeom, a.aid, a.bid from _segmentintersections a inner join wdnearbysegments b on a.bid = b.id union all
				select st_endpoint(b.mercgeom) as mercgeom, a.aid, a.bid from _segmentintersections a inner join wdnearbysegments b on a.bid = b.id
			) b on a.aid = b.aid and a.bid = b.bid
		) a order by 1,2,3,4;
		--Populate ties
		insert into _ties (x0, y0, x1, y1, mercgeom) select *, st_setsrid(st_centroid(st_collect(st_makepoint(x0, y0), st_makepoint(x1, y1))), 3857) as mercgeom
		from _closestintersectionpoints order by 1,2,3,4;
		--Add any segments which are passed over in the same direction by multiple polygons more than once. This uses retrace map from last back-population.
		insert into _ties (x0, y0, x1, y1, mercgeom)
		select a.*, st_setsrid(st_centroid(st_collect(st_makepoint(a.x0, a.y0), st_makepoint(a.x1, a.y1))), 3857) as mercgeom from (
			select x0, y0, x1, y1 from _retracemap where wscount0 > 1 union select x1, y1, x0, y0 from _retracemap where wscount0 > 1
		) a left join _ties b on a.x0 = b.x0 and a.y0 = b.y0 and a.x1 = b.x1 and a.y1 = b.y1 where b.id is null;
		--Only have one connexion per tie.  The above should create points both ways, so no points should be missed.
		delete from _ties where x0 > x1 or (x0 = x1 and y0 > y1);
		--Populate moved points.  This should ensure they are unique by x/y.
		insert into _movedpoints (tieid, x, y, mercgeom)
		select tieid, x, y, st_setsrid(st_makepoint(x, y), 3857) as mercgeom from (
			select distinct x, y, first_value(tieid) over (partition by x, y order by thedistance, tieid) as tieid from (
				select id as tieid, x0 as x, y0 as y, st_distance(st_setsrid(st_makepoint(x0, y0), 3857), mercgeom) as thedistance from _ties
				union select id as tieid, x1 as x, y1 as y, st_distance(st_setsrid(st_makepoint(x1, y1), 3857), mercgeom) as thedistance from _ties
			) a
		) a order by 2,3;
	end
	--Don't launch if there are no points moved and no tie points to move to...
	--When there are no more moves to make, check to see if the boundary has been calculated.
	if (select 1 from _movedpoints limit 1) and (select 1 from _ties limit 1) begin
		select raisenotice(now()::text || ' - Start back-population.');
		--Populate nearby segments which may be affected by move.  First grab maximum point movement, then create bounding box with envelope matching maximum point movement.
		--...then load any new overlapping segments into nearby table.
		set @tolerance = (select max(st_distance(a.mercgeom, b.mercgeom)) * 1.01 from _movedpoints a inner join _ties b on a.tieid = b.id); set @tolerance = @tolerance[0][0];
		drop table if exists _matchboxes; select st_expand(st_envelope(b.mercgeom), @tolerance) as mercgeom into temp _matchboxes from (
			select b.id from (select distinct x, y from _movedpoints order by 1,2) a inner join (select id, x0 as x, y0 as y from wdnearbysegments order by 2,3) b
				on a.x = b.x and a.y = b.y union
			select b.id from (select distinct x, y from _movedpoints order by 1,2) a inner join (select id, x1 as x, y1 as y from wdnearbysegments order by 2,3) b
				on a.x = b.x and a.y = b.y
		) a inner join wdnearbysegments b on a.id = b.id;
		--Add nearby segments which may have been missed.
		insert into wdnearbysegments select b.* from (select distinct b.id from _matchboxes a inner join wdwssegments b on a.mercgeom && b.mercgeom) a
		inner join wdwssegments b on a.id = b.id left join wdnearbysegments c on b.id = c.id where c.id is null order by b.id;
		--When nearby segments are added, populate _tieupdate:
		drop table if exists _tieupdate; select a.x, a.y, b.mercgeom into temp _tieupdate from _movedpoints a inner join _ties b on a.tieid = b.id order by 1,2;
		--Back-populate unconnected points:
		update wdunconnectedpoints a set x = st_x(b.mercgeom), y = st_y(b.mercgeom), mercgeom = b.mercgeom from _tieupdate b where a.x = b.x and a.y = b.y;
		--Nearby segments should be the superset.  Use that as the baseline.
		drop table if exists _segmentstoupdate; select b.* into temp _segmentstoupdate from (
			select b.id from _tieupdate a inner join wdnearbysegments b on a.x = b.x0 and a.y = b.y0 union
			select b.id from _tieupdate a inner join wdnearbysegments b on a.x = b.x1 and a.y = b.y1 order by 1
		) a inner join wdnearbysegments b on a.id = b.id order by 1;
		update _segmentstoupdate a set x0 = st_x(b.mercgeom), y0 = st_y(b.mercgeom) from _tieupdate b where a.x0 = b.x and a.y0 = b.y;
		update _segmentstoupdate a set x1 = st_x(b.mercgeom), y1 = st_y(b.mercgeom) from _tieupdate b where a.x1 = b.x and a.y1 = b.y;
		update _segmentstoupdate a set mercgeom = st_setsrid(st_makeline(st_makepoint(x0, y0), st_makepoint(x1, y1)), 3857);
		--Now update tables on disk.  Using scratch tables in memory should be faster.
		update wdnearbysegments a set x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1, mercgeom = b.mercgeom from _segmentstoupdate b where a.id = b.id;
		update wdunconnectedsegments a set x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1, mercgeom = b.mercgeom from _segmentstoupdate b where a.id = b.id;
		update wdboundarysegments a set x0 = b.x0, y0 = b.y0, x1 = b.x1, y1 = b.y1, mercgeom = b.mercgeom from _segmentstoupdate b where a.id = b.id;
		--For anybody who now matches or is a zero-length segment, hive off and delete.  This may result in finished segments having points which are out of synch.
		insert into wdfinishedsegments select * from wdunconnectedsegments where x0 = x1 and y0 = y1;
		delete from wdunconnectedsegments where x0 = x1 and y0 = y1;
		--Any segment that doesn't double back on itself and end where it started.  This takes into account multiple passes.
		drop table if exists _uncollapsedsegments; select a.wsid, a.x0, a.y0, a.x1, a.y1 into temp _uncollapsedsegments
		from wdunconnectedsegments a left join wdunconnectedsegments b on a.wsid = b.wsid and a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0
		group by 2,3,4,5,1 having count(distinct a.id) > count(distinct b.id) order by 2,3,4,5,1;
		--The retrace map will tell you how many polygons are on each side of each segment.  Any 1 to 1 match counts as a finished segment.
		--More than 1 polygon on a side means the points for a segment have to be collapsed.
		drop table if exists _retracemap; select a.x0, a.y0, a.x1, a.y1, count(distinct a.wsid) as wscount0, count(distinct b.wsid) as wscount1
		into temp _retracemap from _uncollapsedsegments a left join _uncollapsedsegments b on a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0
		group by 1,2,3,4 order by 1,2,3,4;
		--Find only the segments for which there is not a 1 to 1 match with a segment in another polygon.
		drop table if exists _perfectmatches; select x0, y0, x1, y1 into temp _perfectmatches from _retracemap where wscount0 = 1 and wscount1 = 1;
		--Hive off anyone who is perfectly matched.
		insert into wdfinishedsegments select b.* from (select * from _perfectmatches order by x0,y0,x1,y1) a
		inner join (select * from wdunconnectedsegments order by x0,y0,x1,y1) b on a.x0 = b.x0 and a.y0 = b.y0 and a.x1 = b.x1 and a.y1 = b.y1;
		delete from wdunconnectedsegments a using _perfectmatches b where a.x0 = b.x0 and a.y0 = b.y0 and a.x1 = b.x1 and a.y1 = b.y1;
		--Adding all points from active segments.
		drop table if exists _allpoints; select a.x, a.y into temp _allpoints from (
			select x0 as x, y0 as y from wdunconnectedsegments union select x1, y1 from wdunconnectedsegments
		) a order by 1,2;
		--Hive off anyone who's not a member.
		insert into wdfinishedpoints select a.* from wdunconnectedpoints a left join _allpoints b on a.x = b.x and a.y = b.y where b.x is null order by a.id;
		delete from wdunconnectedpoints c using wdunconnectedpoints a left join _allpoints b on a.x = b.x and a.y = b.y where c.id = a.id and b.x is null;
		--If unconnected segments have been exhausted, populate intersecting segments with dummy value to trigger one or more passes.
		if not (select 1 from wdunconnectedsegments limit 1) begin
			drop table if exists _segmentintersections; select 1 as id into temp _segmentintersections;
		end
		select raisenotice(now()::text || ' - End Back-population.');
	end else if not (select 1 from _movedpoints limit 1) and not (select 1 from _ties limit 1) and not (select 1 from wdboundarysegments limit 1) begin
		select raisenotice(now()::text || ' - Begin Boundary calculation.');
		--If there are no changes made, and no boundaries yet, calculate boundaries here.
		--Retrace map has to be recalculated, since the last few matching segments have now been hived off.
		--Any segment that doesn't double back on itself and end where it started.  This takes into account multiple passes.
		drop table if exists _uncollapsedsegments; select a.wsid, a.x0, a.y0, a.x1, a.y1 into temp _uncollapsedsegments
		from wdunconnectedsegments a left join wdunconnectedsegments b on a.wsid = b.wsid and a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0
		group by 2,3,4,5,1 having count(distinct a.id) > count(distinct b.id) order by 2,3,4,5,1;
		--The retrace map will tell you how many polygons are on each side of each segment.  Any 1 to 1 match counts as a finished segment.
		drop table if exists _retracemap; select a.x0, a.y0, a.x1, a.y1, count(distinct a.wsid) as wscount0, count(distinct b.wsid) as wscount1
		into temp _retracemap from _uncollapsedsegments a left join _uncollapsedsegments b on a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0
		group by 1,2,3,4 order by 1,2,3,4;

		--Find external bounds to all geometries:
		drop table if exists _uncompletedrings; drop table if exists _completedrings;
		create temp table _uncompletedrings (id serial primary key, mercgeom geometry(linestring, 3857)); alter table _uncompletedrings alter column mercgeom set storage external;
		create temp table _completedrings (id serial primary key, mercgeom geometry(linestring, 3857)); alter table _completedrings alter column mercgeom set storage external;

		--This part knits together all the simple segments, and repeatedly connects more until everything is completely added up.
		--From this, one can determine both the exterior of the combined polygons, and through process of elimination, which segments within the outer boundary need to be snapped.

		--Create table of uncompleted rings.
		insert into _uncompletedrings (mercgeom) select geom(st_dump(mercgeom)) from (
			select st_linemerge(st_collect(mercgeom)) as mercgeom from (
				--The polygon count values should always be 1 and 0 at this point, but filter anyway, just in case.
				select st_setsrid(st_makeline(st_makepoint(x0, y0), st_makepoint(x1, y1)), 3857) as mercgeom from _retracemap where wscount0 > wscount1
			) a
		) a;

		--Will repeat until all rings are completed.
		while (select 1 from _uncompletedrings limit 1) begin
			--This should tell you if you're in a loop.
			set @remainingrings = (select count(*) from _uncompletedrings); set @remainingrings = @remainingrings[0][0]; print (cast (@remainingrings as string) + ' rings remaining.');

			--Add polygons to completed rings.
			insert into _completedrings (mercgeom) select mercgeom from _uncompletedrings where st_intersects(st_endpoint(mercgeom), st_startpoint(mercgeom));
			--Clear out those lines:
			delete from _uncompletedrings where st_intersects(st_endpoint(mercgeom), st_startpoint(mercgeom));
			--Add the linestrings from the ringdump back in.  This should connect large polygon borders interrupted by overlapping polygons... hopefully.
			--Add possible connexions for existing segments, and sort by total length descending:
			drop table if exists _swap; select id, st_length(mercgeom) as thelength, st_x(st_startpoint(mercgeom)) as x, st_y(st_startpoint(mercgeom)) as y
			into temp _swap from _uncompletedrings where not st_intersects(st_endpoint(mercgeom), st_startpoint(mercgeom)) union all
			select id, st_length(mercgeom) as thelength, st_x(st_endpoint(mercgeom)) as x, st_y(st_endpoint(mercgeom)) as y from _uncompletedrings
			where not st_intersects(st_endpoint(mercgeom), st_startpoint(mercgeom)) order by 3, 4;
			drop table if exists _swap2; create temp table _swap2 (id serial primary key, id0 int, id1 int, thedistance double precision);
			insert into _swap2 (id0, id1, thedistance) select distinct a.id, b.id, a.thelength + b.thelength
			from _swap a inner join _swap b on a.x = b.x and a.y = b.y and a.id < b.id order by a.thelength + b.thelength desc, a.id, b.id;
			--Find first appearance of each line in ranking:
			drop table if exists _firstappearance; select least(a.id, b.id) as id, coalesce(a.lineid, b.lineid) as lineid into temp _firstappearance
			from (select id0 as lineid, min(id) as id from _swap2 group by 1) a
			full outer join (select id1 as lineid, min(id) as id from _swap2 group by 1) b on a.lineid = b.lineid order by 1, 2;
			--Where lines have identical positions in ranking, export as a path to connect.
			drop table if exists _swap3; select a.id0, a.id1 into temp _swap3 from _swap2 a inner join (
				select id, count(*) from _firstappearance group by 1 having count(*) = 2
			) b on a.id = b.id;
			--Create the actual lengthened lines:
			drop table if exists _swap4; select st_linemerge(st_collect(b.mercgeom, c.mercgeom)) as mercgeom into temp _swap4
			from _swap3 a inner join _uncompletedrings b on a.id0 = b.id inner join _uncompletedrings c on a.id1 = c.id
			union all select a.mercgeom from _uncompletedrings a left join (select id0 as id from _swap3 union select id1 from _swap3) b on a.id = b.id
			where b.id is null;
			truncate _uncompletedrings; insert into _uncompletedrings (mercgeom) select mercgeom from _swap4 order by st_length(mercgeom) desc;
		end
		--End repeat

		--Generating polygons from linestrings and removing any geometries which are completely encapsulated by other geometries:
		--If intersections are VERY close to endpoints, sometimes it will cause the within statement to fail!
		drop table if exists wdboundarypolygons; create table wdboundarypolygons (id serial primary key, mercgeom geometry(polygon, 3857)); alter table wdboundarypolygons alter column mercgeom set storage external;
		insert into wdboundarypolygons (mercgeom) select st_forcerhr(st_makepolygon(mercgeom)) from _completedrings where st_npoints(mercgeom) > 3;
		create index ix_wdboundarypolygons_mercgeom on wdboundarypolygons using gist(mercgeom);
		delete from wdboundarypolygons a using wdboundarypolygons b where a.id != b.id and st_within (a.mercgeom, b.mercgeom);

		--Does everything really match up?
		drop table if exists _boundarypoints; create temp table _boundarypoints (id serial primary key, boundaryid int, ordinal int, mercgeom geometry(point));
		insert into _boundarypoints (boundaryid, ordinal, mercgeom)
		select id as boundaryid, (path(st_dumppoints(mercgeom)))[2] as ordinal, geom(st_dumppoints(mercgeom)) as mercgeom from wdboundarypolygons order by 1, 2;
		drop table if exists _boundarysegments; create temp table _boundarysegments (id serial primary key, boundaryid int, ordinal int,
			x0 double precision, y0  double precision, x1  double precision, y1  double precision, mercgeom geometry(linestring));
		--If there are errors, the segments themselves may not be unique.  They should be unique including the boundary ID.
		insert into _boundarysegments (boundaryid, ordinal, x0, y0, x1, y1, mercgeom)
		select a.boundaryid, a.ordinal, st_x(a.mercgeom), st_y(a.mercgeom), st_x(b.mercgeom), st_y(b.mercgeom), st_makeline(a.mercgeom, b.mercgeom)
		from _boundarypoints a inner join _boundarypoints b on a.boundaryid = b.boundaryid and a.ordinal + 1 = b.ordinal order by 3, 4, 5, 6;

		--This should be a complete collection of segments which lie on the outer boundary.
		--Also includes slight deviations into the interior where polygons don't align precisely.  Perhaps an exteriorring could fix this without moving points?
		drop table if exists _segmentsinboundary; select a.id as isid, b.id as segmentid into temp _segmentsinboundary
		from _boundarysegments a inner join wdunconnectedsegments b on a.x0 = b.x0 and a.y0 = b.y0 and a.x1 = b.x1 and a.y1 = b.y1;
		--Anything here that matches could also be regarded as a failure.  It should only match in the clockwise direction...
		insert into _segmentsinboundary select a.id as isid, b.id as segmentid
		from _boundarysegments a inner join wdunconnectedsegments b on a.x1 = b.x0 and a.y1 = b.y0 and a.x0 = b.x1 and a.y0 = b.y1;

		--Because _segmentsinboundary may not have unique x/y values, this statement must use a distinct keyword:
		insert into wdboundarysegments select distinct b.* from _segmentsinboundary a inner join wdunconnectedsegments b on a.segmentid = b.id order by b.id;
		delete from wdunconnectedsegments a using _segmentsinboundary b where a.id = b.segmentid;

		--Adding points from boundary to be removed.
		drop table if exists _distinctboundarypoints; select a.x, a.y into temp _distinctboundarypoints from (
			select x0 as x, y0 as y from wdboundarysegments union select x1, y1 from wdboundarysegments
		) a order by 1,2;

		--Adding points from internal segments to keep.  The intersection of the two should stay in the dataset.
		drop table if exists _allpoints; select a.x, a.y into temp _allpoints from (
			select x0 as x, y0 as y from wdunconnectedsegments union select x1, y1 from wdunconnectedsegments
		) a order by 1,2;

		--Hive off anyone who's a member.
		insert into wdboundarypoints select distinct a.* from wdunconnectedpoints a inner join _distinctboundarypoints b on a.x = b.x and a.y = b.y order by a.id;
		delete from wdunconnectedpoints a using _distinctboundarypoints b where a.x = b.x and a.y = b.y;

		--Add back any of the points which sit on the boundary.  This will require updating the boundary segment tables too on snap cycles.
		insert into wdunconnectedpoints select distinct b.* from (
			select distinct a.x, a.y from _distinctboundarypoints a inner join _allpoints b on a.x = b.x and a.y = b.y
		) a inner join wdboundarypoints b on a.x = b.x and a.y = b.y order by b.x, b.y, b.wsid, b.ordinal;

		--Get rid of points in boundary dataset
		delete from wdboundarypoints b using (
			select distinct a.x, a.y from _distinctboundarypoints a inner join _allpoints b on a.x = b.x and a.y = b.y
		) a where a.x = b.x and a.y = b.y;

		--For any segment that doubles back on itself, grab the smallest ID value from the match and move to finished segments.
		--Repeat until there are no more double-backs.
		while (select 1 from wdunconnectedsegments a inner join wdunconnectedsegments b on a.wsid = b.wsid
				and a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0 limit 1) begin
			insert into wdfinishedsegments select a.* from wdunconnectedsegments a inner join (
				select min(a.id) as id from wdunconnectedsegments a inner join wdunconnectedsegments b on a.wsid = b.wsid
					and a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0 group by a.wsid, a.x0, a.y0, a.x1, a.y1
			) b on a.id = b.id order by a.id;
			delete from wdunconnectedsegments a using wdfinishedsegments b where a.id = b.id;
		end
		--It could also theoretically happen that everything is perfectly aligned after boundary calculation.
		--Populate intersections just in case.  It's not possible to do this outside of the if statement, because it will trigger an endless loop.
		--If unconnected segments have been exhausted, populate intersecting segments with dummy value to trigger one or more passes.
		if not (select 1 from wdunconnectedsegments limit 1) begin
			drop table if exists _segmentintersections; select 1 as id into temp _segmentintersections;
		end
		select raisenotice(now()::text || ' - End Boundary calculation.');
	end
	--Just before the loop is about to exit, check to see if any reversed polygon paths are causing an overlap where there should be none.
	--Close the part of the loop that doesn't obey the RHR, for simplicity.  This part should only be triggered with very large open spaces to close.
	--Creating polygons, making valid, and forcing RHR will identify reversed segments which need to be re-added to unconnected list.
	if not (select 1 from wdunconnectedsegments limit 1) and not (select 1 from _segmentintersections limit 1) begin
		select raisenotice(now()::text || ' - Running final invalid polygon check before exiting loop.');
		--Recreate all polygons from nearby segments, filling in the blanks with the original data.
		drop table if exists _backpopulatepoints;
		select wsid, ordinal, st_makepoint(x1, y1) as mercgeom into temp _backpopulatepoints from wdnearbysegments
		union all select wsid, 0, st_makepoint(x0, y0) from wdnearbysegments where ordinal = 1 order by 1, 2;
		drop table if exists _wsids; select distinct wsid into temp _wsids from _backpopulatepoints order by wsid;
		drop table if exists _originalpoints;
		select a.wsid, ordinal, st_makepoint(x1, y1) as mercgeom into temp _originalpoints from (select * from wdwssegments order by wsid) a
			inner join (select * from _wsids order by wsid) b on a.wsid = b.wsid
		union all select a.wsid, 0, st_makepoint(x0, y0) from (select * from wdwssegments where ordinal = 1 order by wsid) a
			inner join (select * from _wsids order by wsid) b on a.wsid = b.wsid order by 1, 2;
		--This table must not be altered.  It is used after loop ends.
		drop table if exists _updatedpolypoints;
		select a.wsid, a.ordinal, case when b.wsid is null then a.mercgeom else b.mercgeom end as mercgeom into temp _updatedpolypoints
		from _originalpoints a left join _backpopulatepoints b on a.wsid = b.wsid and a.ordinal = b.ordinal order by 1,2;
		--Generate lines to determine which are not simple.
		drop table if exists _updatedpolylines;
		select wsid, st_makeline(mercgeom order by ordinal) as mercgeom into temp _updatedpolylines from _updatedpolypoints group by wsid;
		--Dump the corrected RHR version of the polygons into staging table. Lines which touch head-to-tail are still considered simple!
		drop table if exists _correctedpolygons; create temp table _correctedpolygons (id serial primary key, wsid int, mercgeom geometry); alter table _correctedpolygons alter column mercgeom set storage external;
		insert into _correctedpolygons (wsid, mercgeom) select wsid, st_forcerhr(st_makepolygon(st_exteriorring(mercgeom))) from (
			select wsid, geom(st_dump(st_makevalid(st_makepolygon(mercgeom)))) as mercgeom from _updatedpolylines where not st_issimple(mercgeom)
		) a where st_npoints(a.mercgeom) > 3 and st_geometrytype(a.mercgeom) = 'ST_Polygon';
		--Generating corrected points with ordinal.
		drop table if exists _correctedpoints; select id, wsid, (path(thedump))[2] as ordinal, st_x(geom(thedump)) as x, st_y(geom(thedump)) as y
		into temp _correctedpoints from (select id, wsid, st_dumppoints(mercgeom) as thedump from _correctedpolygons
			where st_geometrytype(mercgeom) = 'ST_Polygon') a order by 1, 3;
		--Generating corrected segments with wsid.
		drop table if exists _correctedsegments; select a.id, a.wsid, a.x as x0, a.y as y0, b.x as x1, b.y as y1 into temp _correctedsegments
		from (select * from _correctedpoints order by id, ordinal) a inner join (select id, ordinal - 1 as ordinal, x, y from _correctedpoints order by 1,2) b
			on a.id = b.id and a.ordinal = b.ordinal;
		--Generating segments prior to st_forcerhr and st_makevalid to compare.
		drop table if exists _originalsegments; select a.wsid, a.x as x0, a.y as y0, b.x as x1, b.y as y1 into temp _originalsegments
		from (select *, st_x(mercgeom) as x, st_y(mercgeom) as y from _updatedpolypoints order by wsid, ordinal) a
		inner join (select wsid, ordinal - 1 as ordinal, st_x(mercgeom) as x, st_y(mercgeom) as y from _updatedpolypoints order by 1,2) b
			on a.wsid = b.wsid and a.ordinal = b.ordinal
		inner join (select distinct wsid from _correctedpolygons order by 1) c on a.wsid = c.wsid;
		--Use segments that no longer match the direction of the original path after RHR to generate external segments which need to be re-marked as unconnected.
		--These should only ever be complete, simple, valid polygons.
		drop table if exists _segmentreversals; select b.*, st_makeline(st_makepoint(x0, y0), st_makepoint(x1, y1)) as mercgeom into temp _segmentreversals from (
			select distinct a.id from _correctedsegments a left join _originalsegments b
			on a.x0 = b.x0 and a.y0 = b.y0 and a.x1 = b.x1 and a.y1 = b.y1 and a.wsid = b.wsid where b.wsid is null
		) a inner join _correctedsegments b on a.id = b.id;
		--See if anyone's missing from working segment subset.
		insert into wdnearbysegments select b.*
		from (select distinct b.id from _segmentreversals a inner join wdwssegments b on st_expand(a.mercgeom, 1) && b.mercgeom) a
		inner join wdwssegments b on a.id = b.id left join wdnearbysegments c on b.id = c.id where c.id is null order by b.id;
		--Find segments that previously had been marked as matched.
		insert into wdunconnectedsegments select b.* from (
			select distinct c.id from (
				--Find reversed polygons which abut 2 or more other polygons.  This is what causes overlaps.
				--If there is only one adjacent polygon, code will enter infinite loop.
				select a.id from _segmentreversals a inner join (select * from wdnearbysegments order by x0, y0, x1, y1) b
				on a.x0 = b.x0 and a.y0 = b.y0 and a.x1 = b.x1 and a.y1 = b.y1 and a.wsid != b.wsid group by 1 having count(distinct b.wsid) > 1
			) a inner join _segmentreversals b on a.id = b.id inner join (select * from wdnearbysegments order by x0, y0, x1, y1) c
				on b.x0 = c.x0 and b.y0 = c.y0 and b.x1 = c.x1 and b.y1 = c.y1 and b.wsid != c.wsid
		) a inner join wdnearbysegments b on a.id = b.id where st_length(b.mercgeom) > 0 order by b.id;
		--Just in case, get rid of any polygons with boundary segments that are mistakenly set to be collapsed.  This could cause an endless loop.
		delete from wdunconnectedsegments a using (select distinct a.wsid from wdunconnectedsegments a inner join wdboundarysegments b
			on a.x0 = b.x0 and a.y0 = b.y0 and a.x1 = b.x1 and a.y1 = b.y1) b where a.wsid = b.wsid;
		--Add points from segments.  This wipes out previous _points table.
		drop table if exists _points; create temp table _points (id serial primary key, wsid int, ordinal int, ordinal1 int, x double precision, y double precision, mercgeom geometry(point));
		truncate _points; insert into _points (wsid, ordinal, x, y, mercgeom) select wsid, ordinal, x, y, st_setsrid(st_makepoint(x, y), 3857) from
		(select x0 as x, y0 as y, wsid, ordinal from wdunconnectedsegments union select x1, y1, wsid, ordinal + 1 from wdunconnectedsegments order by 1, 2) a;
		--Add index just to be thorough.
		create unique index ix__points_wsid_ordinal on _points using btree(wsid, ordinal);
		insert into wdunconnectedpoints select id, wsid, ordinal, x, y, mercgeom from _points order by 1;
		select raisenotice(now()::text || ' - Finished last check before exiting loop.');
	end
	--Increment pass count.
	set @pass = @pass + 1;
end
--Generating final version of polygons.
drop table if exists _updatedpolygons;
select wsid, st_forcerhr(geom(st_dump(st_makevalid(st_makepolygon(st_makeline(mercgeom order by ordinal)))))) as mercgeom into temp _updatedpolygons
from _updatedpolypoints group by wsid;
--Some rings have holes
update _updatedpolygons set mercgeom = st_forcerhr(st_makepolygon(st_exteriorring(mercgeom))) where st_nrings(mercgeom) > 1;
--Update all unique polygons in source table
update wdwsbaseline c set mercgeom = st_setsrid(b.mercgeom, 3857) from (
	select wsid from _updatedpolygons where st_geometrytype(mercgeom) = 'ST_Polygon' group by 1 having count(*) = 1
) a inner join _updatedpolygons b on a.wsid = b.wsid where st_geometrytype(b.mercgeom) = 'ST_Polygon' and c.id = b.wsid;
--Some wsids split.  Update the ones with the largest area.  Add the rest.
drop table if exists _duplicates; create temp table _duplicates (id serial primary key, wsid int, mercgeom geometry); alter table _duplicates alter column mercgeom set storage external;
insert into _duplicates (wsid, mercgeom) select b.wsid, b.mercgeom from (
	select wsid from _updatedpolygons where st_geometrytype(mercgeom) = 'ST_Polygon' group by 1 having count(*) > 1
) a inner join _updatedpolygons b on a.wsid = b.wsid where st_geometrytype(b.mercgeom) = 'ST_Polygon' order by b.wsid, st_area(b.mercgeom) desc;
--Largest polygons
update wdwsbaseline c set mercgeom = st_setsrid(b.mercgeom, 3857) from (select wsid, min(id) as themin from _duplicates group by 1) a
inner join _duplicates b on a.themin = b.id where c.id = b.wsid;
--Add remainder
insert into wdwsbaseline (externalid, mercgeom) select c.externalid, st_setsrid(a.mercgeom, 3857)
from _duplicates a left join (select wsid, min(id) as themin from _duplicates group by 1) b on a.id = b.themin
inner join wdwsbaseline c on a.wsid = c.id where b.themin is null order by a.id;
--Delete anyone fully encapsulated again
delete from wdwsbaseline a using wdwsbaseline b where st_within(a.mercgeom, b.mercgeom) and a.id != b.id;
--Get rid of any geometry in wdwsbaseline that has collapsed to no longer be a polygon
delete from wdwsbaseline a using (
	select a.wsid from _wsids a left join _updatedpolygons b on a.wsid = b.wsid and st_geometrytype(b.mercgeom) = 'ST_Polygon' where b.wsid is null
) b where a.id = b.wsid;
--Remove repeated points from polygons.  There is a known error in PostGIS 2.2 which will not remove repeated points in small polygons (up to 4 vertices).
--This will result in a corrupt wdwssegments table.  Wrap an exterior ring around polygons, remove repeats from that, and re-form polygons and it should work.
update wdwsbaseline set mercgeom = st_makepolygon(st_removerepeatedpoints(st_exteriorring(mercgeom)));
--Use this if bug is known to be fixed: update wdwsbaseline set mercgeom = st_removerepeatedpoints(mercgeom);
--Test for corrupt data, should be zero:  select count(*) from wdwssegments where x0 = x1 and y0 = y1;
--Test fitness of result set.  Should be 100% simple, valid polygons. select distinct st_geometrytype(mercgeom), st_isvalid(mercgeom), st_issimple(mercgeom), st_nrings(mercgeom) from wdwsbaseline;
--This will return zero if there is no 2-dimensional overlap between different geometries.
--select count(*) from wdwsbaseline a, wdwsbaseline b where a.mercgeom && b.mercgeom and st_relate(a.mercgeom, b.mercgeom, '2********') and a.id != b.id;
--End baseline cleanup.


-------------------------------
--5. Chop by Political Boundary
-------------------------------
--Divide baseline geometries which cross state and national boundaries.
--All polygons should be simple, none should have holes, none should overlap and none should cover water (though some certainly will).
--Rough political boundary file.  Includes territories.
select raisenotice(now()::text || ' - Chop by Political Boundary.');
drop table if exists wdusa; create table wdusa (id serial primary key, name varchar, mercgeom geometry(polygon, 3857)); alter table wdusa alter column mercgeom set storage external;
insert into wdusa (name, mercgeom) select name, geom(st_dump(st_transform(st_setsrid(geom, 4269), 3857)))::geometry(polygon, 3857) from cb_2016_us_nation_5m;
create index ix_wdusa_mercgeom on wdusa using gist(mercgeom);

--Create detailed oceans table.
drop table if exists _waterfeatures; create temp table _waterfeatures (id serial primary key, mercgeom geometry(polygon, 3857)); alter table _waterfeatures alter column mercgeom set storage external;
insert into _waterfeatures (mercgeom) select st_transform(a.thegeom::geometry(polygon, 4326), 3857) from (
	select geom(st_dump(st_makevalid(geom(st_dump(wkb_geometry))))) as thegeom from wdwaterv106
	where type ilike 'ocean or sea' or (
		--The Great Lakes are a mess.  Try to grab water features which define boundary.
		(
			(
				--The names are in several places... for some reason.
				name1 in ('Lake Huron', 'Lake Ontario', 'Lake Superior', 'Lake Erie', 'Lake Michigan')
				or name2 in ('Lake Huron', 'Lake Ontario', 'Lake Superior', 'Lake Erie', 'Lake Michigan')
				or name3 in ('Lake Huron', 'Lake Ontario', 'Lake Superior', 'Lake Erie', 'Lake Michigan')
			)
			--There are also lakes with the same name on the East and West coasts!
			and wkb_geometry && st_transform(st_setsrid('POLYGON ((-10300091.895164154 5047935.894922311,-10300091.895164154 6347022.161832896,-8385648.975506449 6347022.161832896,-8385648.975506449 5047935.894922311,-10300091.895164154 5047935.894922311
			))'::geometry, 3857), 4326)
		)
		--The area between Superior and Huron.
		or st_intersects (wkb_geometry, st_transform(st_setsrid('POLYGON ((-9352081.87331988 5785954.290519283,-9360840.04431339 5795914.563413864,-9383336.522747703 5805187.920936405,-9380417.132416531 5836442.570364228,-9407378.560769105 5857736.94689747,-9401711.508949775 5875425.017727502,-9340919.498524228 5876283.661942552,-9352081.87331988 5785954.290519283
		))'::geometry, 3857), 4326))
		--The area between Huron and Erie.
		or st_intersects (wkb_geometry, st_transform(st_setsrid('POLYGON ((-9273135.945254399 5162774.159284764,-9251002.403471135 5224748.076277906,-9230528.877321614 5249094.972239498,-9228868.861687869 5272335.191111926,-9189581.825022575 5269015.159844437,-9186261.793755084 5307748.85796515,-9172981.668685125 5332649.092471323,-9084447.501552064 5287275.33181563,-9168554.960328473 5192654.440692171,-9217248.752251655 5150600.711303968,-9273135.945254399 5162774.159284764
		))'::geometry, 3857), 4326))
		--The area between Erie and Ontario.
		or st_intersects (wkb_geometry, st_transform(st_setsrid('POLYGON ((-8783871.91739995 5290703.33355216,-8800411.551592352 5288234.731433892,-8809298.51921812 5356861.87032177,-8791277.723754756 5360811.633711,-8787574.820577353 5332669.569562733,-8776466.111045143 5318845.397700427,-8781897.035705334 5305021.225838121,-8781156.455069853 5298602.860330621,-8783871.91739995 5290703.33355216
		))'::geometry, 3857), 4326))
	)
) a where st_npoints(a.thegeom) >= 4 and abs(st_y(st_centroid(thegeom))) < 85;
--Patch noding error off SF coast.
insert into _waterfeatures (mercgeom) select st_snap(a.mercgeom, b.mercgeom, 0.001) as mercgeom from _waterfeatures a, _waterfeatures b where
st_intersects(a.mercgeom, st_setsrid('POINT (-13649562.84490945 4555979.31393619)'::geometry, 3857))
and st_intersects(b.mercgeom, st_setsrid('POINT (-13647655.631767577 4539034.458714166)'::geometry, 3857));
--Index table.
create index ix__waterfeatures_mercgeom on _waterfeatures using gist(mercgeom);

--Create working US watershed dataset.  First add coasts.
drop table if exists _watershedmask; create temp table _watershedmask (id serial primary key, simpleid int, externalid int, mercgeom geometry(geometry, 3857)); alter table _watershedmask alter column mercgeom set storage external;
insert into _watershedmask (simpleid, externalid, mercgeom) select a.id as simpleid, a.externalid, st_difference(b.mercgeom, a.mercgeom) as mercgeom from (
select a.id, a.externalid, st_unaryunion(st_collect(b.mercgeom)) as mercgeom from wdwsbaseline a inner join _waterfeatures b on a.mercgeom && b.mercgeom group by 1,2
) a inner join wdwsbaseline b on a.id = b.id;

--Next add any geometries marked as part of Canada or Mexico which haven't already been added.
insert into _watershedmask (simpleid, externalid, mercgeom) select a.id, a.externalid, a.mercgeom from wdwsbaseline a inner join wbdhu12 b on a.externalid = b.id
left join _watershedmask c on a.id = c.simpleid where (b.states ilike '%CN%' or b.states ilike '%MX%') and c.simpleid is null order by a.id;

--Update any Mexican or Canadian watershed geometries using US geometries.
update _watershedmask a set mercgeom = st_intersection (a.mercgeom, b.mercgeom) from (
	select a.simpleid, st_unaryunion(st_collect(c.mercgeom)) as mercgeom
	from _watershedmask a inner join wbdhu12 b on a.externalid = b.id inner join wdusa c on a.mercgeom && c.mercgeom
	where (b.states ilike '%CN%' or b.states ilike '%MX%') group by 1
) b where a.simpleid = b.simpleid;

--For any Mexican or Canadian watersheds that did not have bounding boxes that overlap the US geometries, mark them as empty geometries.
update _watershedmask a set mercgeom = st_setsrid('GEOMETRYCOLLECTION EMPTY'::geometry, 3857)
from wbdhu12 b where a.externalid = b.id and (b.states ilike '%CN%' or b.states ilike '%MX%') and a.simpleid not in (
	select distinct a.simpleid from _watershedmask a inner join wdusa b on a.mercgeom && b.mercgeom
);

--In part of Montana, the geometries have been split apart based on the Northern parallel.
--This causes razor-thin boundary geometries and ugly districts in the state-agnostic map. Mask out by attribute and bounding box.
update _watershedmask a set mercgeom = st_setsrid('GEOMETRYCOLLECTION EMPTY'::geometry, 3857)
from wbdhu12 b where a.externalid = b.id and b.mercgeom && 'POLYGON ((-12552615.039863594 6264994.384882702,-12552615.039863594 6285035.59531305,-11627379.158329187 6285035.59531305,-11627379.158329187 6264994.384882702,-12552615.039863594 6264994.384882702))'::geometry
	and b.hutype is null;

--Before adding final watersheds, save bounding boxes of boundary and state segments.  This is used later to limit the number of geometries which need to be noded.
drop table if exists _boundaryboxes; select mercgeom into temp _boundaryboxes from (
	select st_expand(st_collect(
		lag(geom(thedump)) over (partition by stateid, (path(thedump))[1], (path(thedump))[2] order by stateid, (path(thedump))[1], (path(thedump))[2], (path(thedump))[3]),
		geom(thedump)
	), 1) as mercgeom from (
		select stateid, st_dumppoints(mercgeom) as thedump from wdcensusstates
	) a
) a where mercgeom is not null
union all select st_expand(mercgeom, 1) from _watershedmask;

--Add remaining watersheds.
insert into _watershedmask (simpleid, externalid, mercgeom) select a.id, a.externalid, a.mercgeom from wdwsbaseline a left join _watershedmask b on a.id = b.simpleid where b.simpleid is null order by a.id;

--Generate US-only baseline from mask.
drop table if exists _uswatersheds; create temp table _uswatersheds(id serial primary key, externalid int, mercgeom geometry(polygon, 3857)); alter table _uswatersheds alter column mercgeom set storage external;
insert into _uswatersheds(externalid, mercgeom) select externalid, st_forcerhr(st_makepolygon(st_removerepeatedpoints(st_exteriorring(mercgeom)))) from (
	select externalid, geom(st_dump(st_makevalid(mercgeom))) as mercgeom from _watershedmask
) a where st_geometrytype(a.mercgeom) = 'ST_Polygon' order by 1;
create index ix__uswatersheds_mercgeom on _uswatersheds using gist(mercgeom);
delete from _uswatersheds a using _uswatersheds b where st_within(a.mercgeom, b.mercgeom) and a.id != b.id;
--Sanity check. Should be simple, valid polygons with only one ring: select distinct st_geometrytype(mercgeom), st_isvalid(mercgeom), st_issimple(mercgeom), st_nrings(mercgeom) from _uswatersheds;

--Create permanent destination table.
drop table if exists wdws; create table wdws (id serial primary key, externalid int, parentid int, stateid int, basinid int, islandid int,
	boundary boolean, population int, exitmercgeom geometry (point, 3857), mercgeom geometry (polygon, 3857));
alter table wdws alter column mercgeom set storage external;

--Use census block geometries to divide watersheds by state boundary.  Around 30 minutes for all states.
insert into wdws (externalid, parentid, stateid, basinid, islandid, boundary, population, mercgeom)
select externalid, null, stateid, null, null, null, null, mercgeom from (
	select b.externalid, a.stateid, st_forcerhr(geom(st_dump(st_makevalid(st_intersection(a.mercgeom, b.mercgeom))))) as mercgeom
	from wdcensusstates a inner join _uswatersheds b on st_intersects (a.mercgeom, b.mercgeom) order by a.stateid, b.externalid
) a where st_geometrytype(mercgeom) = 'ST_Polygon';

--Watershed table always needs a geometry index.
create index ix_wdws_mercgeom on wdws using gist(mercgeom);

--After splitting watersheds by either US or state boundaries, many small boundary geometries are created which do not quite fit a model
--where each boundary basin is adjacent and not embedded. The following process merges the majority of those small geometries,
--though it still does not technically meet the criterion that no basin is embedded, in the interest of preserving as much legitimate data as possible.
--Simple network between watershed polygons.  This is a simplified, unordered version of final watershed connexion table below.
drop table if exists _simpleconnections; create temp table _simpleconnections (id serial primary key, wsid0 int, wsid1 int);
insert into _simpleconnections (wsid0, wsid1) select a.id, b.id from wdws a, wdws b
where st_relate(a.mercgeom, b.mercgeom, '****1****') and a.mercgeom && b.mercgeom and a.id != b.id and a.stateid = b.stateid order by 1,2;
--List of polygons which are only adjacent to a single, larger polygon.
drop table if exists _deadends; select 1 as wsid0, 1 as wsid1 into temp _deadends where 1=0;
set @lastcount = 0; set @thiscount = 1;
while @lastcount < @thiscount begin
	select raisenotice(now()::text || ' - Removing embedded boundary polygons.  Last count: @lastcount.  Current count: @thiscount');
	insert into _deadends select distinct b.wsid0, b.wsid1 from (
		select a.wsid0 from _simpleconnections a inner join wdws b on a.wsid0 = b.id left join _deadends c on a.wsid0 = c.wsid0
		left join _deadends d on a.wsid1 = d.wsid0 where c.wsid0 is null and d.wsid0 is null
		group by 1 having count(distinct a.wsid1) = 1 order by 1
	) a inner join _simpleconnections b on a.wsid0 = b.wsid0 left join _deadends c on b.wsid1 = c.wsid0
	inner join wdws d on b.wsid0 = d.id inner join wdws e on b.wsid1 = e.id
	where c.wsid0 is null and st_area(d.mercgeom) < st_area(e.mercgeom) order by 1,2;
	set @lastcount = @thiscount;
	set @thiscount = select count(*) from _deadends; set @thiscount = @thiscount[0][0];
end
--Update the nested links.  Assumes no cyclical dependencies.  Without the area comparison, there may be some.
set @linkstoprocess = 1;
while @linkstoprocess > 0 begin
	update _deadends a set wsid1 = b.wsid1 from _deadends b where a.wsid1 = b.wsid0;
	set @linkstoprocess = select count(*) from _deadends a, _deadends b where a.wsid1 = b.wsid0; set @linkstoprocess = @linkstoprocess[0][0];
end
--Update geometries.
update wdws a set mercgeom = st_forcerhr(st_makepolygon(st_exteriorring(st_makevalid(st_unaryunion(st_collect(a.mercgeom, b.mercgeom)))))) from (
	select a.wsid1, st_collect(b.mercgeom) as mercgeom from _deadends a inner join wdws b on a.wsid0 = b.id group by 1 order by 1
) b where a.id = b.wsid1;
--Delete.
delete from wdws a using _deadends b where a.id = b.wsid0;
--Clean up temporary table in case it's used later.
delete from _simpleconnections a using _deadends b where a.wsid0 = b.wsid0;
delete from _simpleconnections a using _deadends b where a.wsid1 = b.wsid0;

--The state intersection and the dead end union queries result in non-noded self-intersections in polygons which aren't caught by st_isvalid.
--Without noding them, they can cause functions like st_intersection to error out.
--They can be noded by snapping, but snap must be done on actual deconstructed segments, not source polygon.  Snap will not node segments within a polygon to cause a self-intersection.
--This uses relatively new functions which might help the edge-matching above go faster.
--Dump limited segments table based on boundary boxes from above.
drop table if exists _segments; select wsid, ordinal, mercgeom into temp _segments from (
	select wsid, (path(thedump))[1] as ordinal, st_makeline(
		lag(geom(thedump)) over (partition by wsid order by wsid, (path(thedump))[1]), geom(thedump)
	) as mercgeom from (
		select b.id as wsid, st_dumppoints(st_exteriorring(b.mercgeom)) as thedump from (
			select distinct b.id from _boundaryboxes a inner join wdws b on a.mercgeom && b.mercgeom
		) a inner join wdws b on a.id = b.id
	) a
) a where mercgeom is not null;

--Dump and index distinct points.
drop table if exists _points; select distinct geom(st_dumppoints(mercgeom)) as mercgeom into temp _points from _segments;
create index ix__points_mercgeom on _points using gist(mercgeom);

--Find individual segments which need to be noded.  Tolerance is t.  Will not snap to points within 2t of segment endpoints to avoid disconnections in st_linemerge.
drop table if exists _nodedsegments; select b.wsid, b.ordinal, st_snap(b.mercgeom, st_collect(c.mercgeom), a.t) as mercgeom into temp _nodedsegments
from (select 1.0/power(2, 10)::double precision as t) a inner join _segments b on 0=0 inner join _points c on st_expand(b.mercgeom, a.t) && c.mercgeom
where not st_startpoint(b.mercgeom) = c.mercgeom and not st_endpoint(b.mercgeom) = c.mercgeom and st_distance(b.mercgeom, c.mercgeom) < a.t
	and st_distance (st_startpoint(b.mercgeom), c.mercgeom) > 2.0 * a.t and st_distance (st_endpoint(b.mercgeom), c.mercgeom) > 2.0 * a.t
group by a.t, b.wsid, b.ordinal, b.mercgeom order by b.wsid, b.ordinal;

--Find largest resulting polygon and back-populate.
update wdws b set mercgeom = a.mercgeom from (
	select distinct wsid, first_value(mercgeom) over (partition by wsid order by st_area(mercgeom) desc) as mercgeom from (
		select wsid, st_forcerhr(geom(st_dump(st_makevalid(st_makepolygon(mercgeom))))) as mercgeom from (
			select b.wsid, st_linemerge(st_collect(coalesce(c.mercgeom, b.mercgeom))) as mercgeom
			from (select distinct wsid from _nodedsegments) a inner join _segments b on a.wsid = b.wsid
			left join _nodedsegments c on b.wsid = c.wsid and b.ordinal = c.ordinal group by 1
		) a where st_isclosed(mercgeom)
	) a where st_geometrytype (mercgeom) = 'ST_Polygon'
) a where b.id = a.wsid;

--There are still a few polygons which overlap at nodes.  Snap smaller neighbours to larger ones.
update wdws a set mercgeom = b.mercgeom from (
	select b.id, st_snap(b.mercgeom, a.mercgeom, 1.0/power(2, 10)::double precision) as mercgeom from (
		select a.id, st_collect(b.mercgeom) as mercgeom from wdws a, wdws b
		where a.mercgeom && b.mercgeom and st_relate(a.mercgeom, b.mercgeom, '2********') and a.id != b.id
		and st_area(b.mercgeom) > st_area(a.mercgeom) group by 1
	) a inner join wdws b on a.id = b.id
) b where a.id = b.id;

--Check for validity: select distinct st_geometrytype(mercgeom), st_isvalid(mercgeom), st_issimple(mercgeom), st_nrings(mercgeom) from wdws;
--Should be no overlap: select count(*) from wdws a, wdws b where a.mercgeom && b.mercgeom and st_relate(a.mercgeom, b.mercgeom, '2********') and a.stateid = b.stateid and a.id != b.id;


---------------------------------------
--6. Create Watershed Adjacency Network
---------------------------------------
--Calculate all adjacent watersheds.  Break down new polygons into boundary segments, and then connexions.
--There are simpler ways to create this network, but this method preserves order.  That means district numbering should remain similar for each census. 20 minutes.
select raisenotice(now()::text || ' - Create Watershed Adjacency Network.');
drop table if exists _points; create temp table _points (id serial, stateid int, wsid int, ordinal int, ordinal1 int, x double precision, y double precision, mercgeom geometry(point));
insert into _points (stateid, wsid, ordinal, ordinal1, x, y, mercgeom)
select stateid, id, (path(thedump))[2] as ordinal, (path(thedump))[2] + 1 as ordinal1, st_x(geom(thedump)), st_y(geom(thedump)), geom(thedump)
from (select stateid, id, st_dumppoints(mercgeom) as thedump from wdws) a order by 5, 6, 2, 3;
select raisenotice(now()::text || ' - Done points.');

--Create segments from points. This overwrites previous segments table.  45 minutes.  This can be done much faster with a window function and the lag command.
drop table if exists wdwssegments;
create table wdwssegments (id serial primary key, stateid int, wsid int, ordinal int, x0 double precision, y0 double precision, x1 double precision, y1 double precision, mercgeom geometry(linestring));
insert into wdwssegments (stateid, wsid, ordinal, x0, y0, x1, y1, mercgeom) select a.stateid, a.wsid, a.ordinal, a.x, a.y, b.x, b.y, st_makeline(a.mercgeom, b.mercgeom)
from (select stateid, wsid, ordinal, ordinal1, x, y, mercgeom from _points order by wsid, ordinal1) a
inner join (select wsid, ordinal, x, y, mercgeom from _points order by wsid, ordinal) b on a.wsid = b.wsid and a.ordinal1 = b.ordinal order by 4, 5, 6, 7, 2, 3;
create unique index ix_wdwssegments_wsid_ordinal on wdwssegments using btree(wsid, ordinal);
select raisenotice(now()::text || ' - Done segments.');

--Generate every segment and what it's connected to.  This can be another polygon, or nothing (ID: 0). 35 minutes.
--_connectedsegments temporary table is required by island connexion code below.
--Include ids, wsids, ordinals, and length of each segment match.  With zero-length segments, this can result in polygons linking to themselves and data corruption.
--This should be zero:  select count(*) from _connectedsegments where wsid0 = wsid1;
drop table if exists _connectedsegments;
select a.id as id0, a.wsid as wsid0, a.ordinal as ordinal0, coalesce(b.id, 0) as id1, coalesce(b.wsid, 0) as wsid1, coalesce(b.ordinal, 0) as ordinal1,
	st_length(a.mercgeom) as thelength into temp _connectedsegments from (select * from wdwssegments order by x0, y0, x1, y1) a
left join (select * from wdwssegments order by x1, y1, x0, y0) b on a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0 and a.stateid = b.stateid order by 2, 3;
select raisenotice(now()::text || ' - Done connected segments.');

--Find boundaries within polygon where one external polygon changes to another.  This will not give results for polygons without neighbours:
drop table if exists _intersections; create temp table _intersections (id serial primary key, wsid int, ordinal0 int, ordinal1 int, wsid0 int, outsideordinal0 int, wsid1 int, outsideordinal1 int);
insert into _intersections (wsid, ordinal0, ordinal1, wsid0, outsideordinal0, wsid1, outsideordinal1)
select a.wsid0, a.ordinal0 - 1, b.ordinal0, a.wsid1, a.ordinal1, b.wsid1, b.ordinal1 from
(select wsid0, ordinal0 + 1 as ordinal0, wsid1, ordinal1 from _connectedsegments order by wsid0, ordinal0) a
inner join (select wsid0, ordinal0, wsid1, ordinal1 from _connectedsegments order by wsid0, ordinal0) b on a.wsid0 = b.wsid0 and a.ordinal0 = b.ordinal0
where a.wsid1 != b.wsid1 union all
--These are the boundaries that occur precisely at the endpoint (surprisingly, the majority)
select a.wsid0, a.ordinal0, b.ordinal0, a.wsid1, a.ordinal1, b.wsid1, b.ordinal1
from (select wsid0, max(ordinal0) as themax, min(ordinal0) as themin from _connectedsegments group by 1 order by 1) c
inner join (select * from _connectedsegments order by wsid0, ordinal0) a on c.wsid0 = a.wsid0 and c.themax = a.ordinal0
inner join (select * from _connectedsegments order by wsid0, ordinal0) b on c.wsid0 = b.wsid0 and c.themin = b.ordinal0 where a.wsid1 != b.wsid1 order by 1, 2;

--Should be able to create connectable subset now, based on border connexions on either side:
drop table if exists _connections;
select a.id, a.ordinal1 as l0, c.ordinal0 as r0, a.wsid as wsid0, c.outsideordinal0 as l1, a.outsideordinal1 as r1, a.wsid1 into temp _connections
from _intersections a inner join (select wsid, min(id) as themin, max(id) as themax from _intersections group by wsid) b on a.wsid = b.wsid
inner join _intersections c on case when a.id = b.themax then b.themin else a.id + 1 end = c.id order by a.id;

--Create watershed connexions table.
drop table if exists wdwsconnections; create table wdwsconnections (id serial primary key, wsid0 int, connectionid int, wsid1 int, mercgeom geometry(linestring, 3857));
insert into wdwsconnections (id, wsid0, connectionid, wsid1, mercgeom) select a.id, a.wsid0, least(a.id, b.id) as connectionid, a.wsid1, st_linemerge(st_collect(c.mercgeom)) as mercgeom
from _connections a left join _connections b on a.wsid0 = b.wsid1 and a.l0 = b.l1 and a.r0 = b.r1
inner join (select id, wsid, ordinal, mercgeom from wdwssegments order by 1,2) c
	on a.wsid0 = c.wsid and ((c.ordinal >= a.l0 and c.ordinal <= a.r0) or (a.l0 > a.r0 and (c.ordinal >= a.l0 or c.ordinal <= a.r0))) group by 1,2,3,4 order by 1;

--Add isolated watersheds just to be safe.  Use autoincrement from _intersections.
insert into _intersections (wsid, wsid0) select a.id, a.id from wdws a left join wdwsconnections b on a.id = b.wsid0 where b.id is null order by 1;
insert into wdwsconnections (id, wsid0, connectionid, wsid1, mercgeom) select a.id, a.wsid, a.id, 0, st_linemerge(st_collect(b.mercgeom))
from _intersections a inner join (select * from wdwssegments order by wsid) b on a.wsid = b.wsid where a.wsid = a.wsid0 group by 1,2,3,4 order by 1,2,3,4;
create index ix_wdwsconnections_mercgeom on wdwsconnections using gist(mercgeom);

--Consistency tests:
--Should match:  select count(*), count(distinct id), count(distinct (wsid0, connectionid)) from wdwsconnections;
--Nothing should come from this: select connectionid, count(*) from wdwsconnections group by 1 having count(*) > 2;


-----------------------------
--7. Set Watershed Attributes
-----------------------------
--Set attributes for all watershed polygons, including descent attributes.  Use river and water body geometries to calculate exit points for each watershed and to determine parent geometry.
select raisenotice(now()::text || ' - Set Watershed Attributes.');
--Set boundary polygons.
update wdws set boundary = false; update wdws a set boundary = true from wdwsconnections b where a.id = b.wsid0 and b.wsid1 = 0;

--Should be able to set island IDs just with the connexions table. 5 minutes.
update wdws set islandid = id;
--PGScript
while (select 1 from wdws a inner join wdwsconnections b on a.id = b.wsid0 inner join wdws c on b.wsid1 = c.id where c.islandid < a.islandid limit 1) begin
	update wdws a set islandid = b.islandid from (
		select a.id, min(c.islandid) as islandid from wdws a inner join wdwsconnections b on a.id = b.wsid0 inner join wdws c on b.wsid1 = c.id where c.islandid < a.islandid group by 1
	) b where a.id = b.id;
end

--Set exit point for each watershed, and parent of each watershed based partially on that geometry. 6 hours.
--Simple rivers.
drop table if exists _rivers; create temp table _rivers (id serial primary key, externalid int, mercgeom geometry(linestring, 3857)); alter table _rivers alter column mercgeom set storage external;
insert into _rivers (externalid, mercgeom) select objectid, geom(st_dump(st_transform(st_force2d(wkb_geometry), 3857))) from nhdflowline order by 1;
create index ix__rivers_mercgeom on _rivers using gist(mercgeom);

--Simple water bodies and evaporation playas. 25 minutes.  Used for closed basin evaporation centroid calculation.
drop table if exists _lakes; create temp table _lakes (id serial primary key, externalid int, mercgeom geometry(polygon, 3857)); alter table _lakes alter column mercgeom set storage external;
insert into _lakes (externalid, mercgeom) select * from (
	select objectid as externalid, st_makevalid(geom(st_dump(st_transform(st_force2d(wkb_geometry), 3857)))) as mercgeom from NHDWaterbody
) a where st_geometrytype(a.mercgeom) = 'ST_Polygon' order by 1;
create index ix__lakes_mercgeom on _lakes using gist(mercgeom);

--Intersections between rivers and watershed boundaries. 1.5 hours.  Only certain types of flowline seem to be appropriate to use.
drop table if exists _riverintersections;
select c.wsid0, c.id as connectionid, c.wsid1, b.fcode, a.id as riverid, st_intersection(a.mercgeom, c.mercgeom) as mercgeom into temp _riverintersections
from _rivers a inner join NHDFlowline b on a.externalid = b.objectid inner join wdwsconnections c on a.mercgeom && c.mercgeom
where substring(b.fcode::varchar, 1,3) in ('460', '558', '334', '420') and st_intersects(a.mercgeom, c.mercgeom) order by 1,2,3,4,5;

--All possible descents from one watershed to another based on original tohuc.  Only adjacent polygons are counted, and interfaces with the boundary have a parent of zero.
drop table if exists _possibledescents; select a.id, c.id as parentid, st_collect(d.mercgeom) as mercgeom into temp _possibledescents
from wdws a inner join wbdhu12 b on a.externalid = b.id inner join wdws c on b.parentid = c.externalid
inner join wdwsconnections d on a.id = d.wsid0 and c.id = d.wsid1 group by 1,2
union all select wsid0, wsid1, st_collect (mercgeom) from wdwsconnections where wsid1 = 0 group by 1,2 order by 1,2;

--Record appropriate flow type to use for each watershed where there is no ambiguity between child and parent.
--All boundary polygons have the boundary as one possible option.
--First pick artificial path (558), then stream (460), then conduit (420), then connector (334).
drop table if exists _flowtypes; create temp table _flowtypes (id int primary key, ftype int);
--Artificial path (usually most reliable).
insert into _flowtypes select b.wsid0, fcode / 100 as ftype from _possibledescents a inner join _riverintersections b on a.id = b.wsid0 and a.parentid = b.wsid1
left join _flowtypes c on b.wsid0 = c.id where a.parentid > 0 and b.fcode / 100 = 558 and c.id is null group by 1, 2 having count(distinct a.parentid) = 1;
--Stream
insert into _flowtypes select b.wsid0, fcode / 100 as ftype from _possibledescents a inner join _riverintersections b on a.id = b.wsid0 and a.parentid = b.wsid1
left join _flowtypes c on b.wsid0 = c.id where a.parentid > 0 and b.fcode / 100 = 460 and c.id is null group by 1, 2 having count(distinct a.parentid) = 1;
--Conduit
insert into _flowtypes select b.wsid0, fcode / 100 as ftype from _possibledescents a inner join _riverintersections b on a.id = b.wsid0 and a.parentid = b.wsid1
left join _flowtypes c on b.wsid0 = c.id where a.parentid > 0 and b.fcode / 100 = 420 and c.id is null group by 1, 2 having count(distinct a.parentid) = 1;
--Connector
insert into _flowtypes select b.wsid0, fcode / 100 as ftype from _possibledescents a inner join _riverintersections b on a.id = b.wsid0 and a.parentid = b.wsid1
left join _flowtypes c on b.wsid0 = c.id where a.parentid > 0 and b.fcode / 100 = 334 and c.id is null group by 1, 2 having count(distinct a.parentid) = 1;

--Generate centroids of crossover points.  First start with watershed-to-watershed connexions.
drop table if exists _rivercentroids; select c.id, c.parentid, st_centroid(st_collect(b.mercgeom)) as mercgeom into temp _rivercentroids
from _flowtypes a inner join _riverintersections b on a.id = b.wsid0 and a.ftype = b.fcode / 100
inner join _possibledescents c on b.wsid0 = c.id and b.wsid1 = c.parentid where c.parentid > 0 group by 1, 2
--Add centroid of missing boundary river crossings, if they exist.
union all select wsid0, wsid1, st_centroid(st_collect(a.mercgeom)) from _riverintersections a left join _flowtypes b on a.wsid0 = b.id
where b.id is null and a.wsid1 = 0 group by 1, 2
order by 1, 2;

--If boundary watersheds are still missing, add centroid of existing composite boundary geometry.
insert into _rivercentroids select a.id, a.parentid, st_centroid(st_collect(a.mercgeom)) from _possibledescents a
left join _rivercentroids b on a.id = b.id where b.id is null and a.parentid = 0 group by 1, 2 order by 1, 2;

--Find closest point on the collected watershed boundary to the centroid of the collected intersections of that boundary.
drop table if exists _exitpoints; create temp table _exitpoints (id int primary key, parentid int, mercgeom geometry(point, 3857));
insert into _exitpoints select a.id, case when a.parentid = 0 then null else a.parentid end, st_closestpoint (b.mercgeom, a.mercgeom)
from _rivercentroids a inner join _possibledescents b on a.id = b.id and a.parentid = b.parentid 
--Include closed basins. Grabs centroid of whatever water boundaries or evaporation playa happen to intersect watershed and snaps to be within watershed.
union all select a.id, null, st_closestpoint(b.mercgeom, coalesce(a.mercgeom, st_centroid(b.mercgeom))) from (
	select a.id, st_centroid(st_collect(b.mercgeom)) as mercgeom from (
		select a.id, a.mercgeom from wdws a inner join wbdhu12 b on a.externalid = b.id where not a.boundary and b.parentid is null
	) a left join _lakes b on st_intersects (a.mercgeom, b.mercgeom) group by 1
) a inner join wdws b on a.id = b.id
order by 1;

--Frequently, 2 river crossings will come together quite close to one another, and the alteration of the polygons
--(or NHD Flowline data error) sometimes moves the crossing from the correct descent into a sibling.  This query examines
--neighbours of both parent and child and selects closest crossing geometry, then selects closest point on actual interface to that geometry.
drop table if exists _closestneighborcrossings; select distinct e.wsid0,
first_value(e.wsid1) over (partition by e.wsid0 order by st_distance(h.mercgeom, e.mercgeom), st_length(e.mercgeom) desc, h.riverid) as wsid1,
first_value(h.mercgeom) over (partition by e.wsid0 order by st_distance(h.mercgeom, e.mercgeom), st_length(e.mercgeom) desc, h.riverid) as mercgeom
into temp _closestneighborcrossings
from wdws a left join _exitpoints b on a.id = b.id inner join wbdhu12 c on a.externalid = c.id inner join wdws d on c.parentid = d.externalid
--Connexion between child and parent.
inner join wdwsconnections e on a.id = e.wsid0 and d.id = e.wsid1
--Connexion between child and neighbours of parent.
inner join wdwsconnections f on a.id = f.wsid0 inner join wdwsconnections g on d.id = g.wsid0 and f.wsid1 = g.wsid1
inner join _riverintersections h on f.wsid0 = h.wsid0 and f.wsid1 = h.wsid1 where b.id is null order by 1,2;
--Closest point on actual interface.
insert into _exitpoints select a.wsid0, a.wsid1, st_closestpoint(st_collect(b.mercgeom), st_collect(a.mercgeom))
from _closestneighborcrossings a inner join wdwsconnections b on a.wsid0 = b.wsid0 and a.wsid1 = b.wsid1 group by 1,2 order by 1,2;

--Some watersheds have been detached from their parent either through the cleaning procedure, or because of data error.
--Find discrete list of every watershed which does not abut any parent it is supposed to abut for all polygons not on the boundary.
drop table if exists _disconnectedwatersheds; select a.id into temp _disconnectedwatersheds
from wdws a inner join wbdhu12 b on a.externalid = b.id inner join wdws c on b.parentid = c.externalid
left join wdwsconnections d on a.id = d.wsid0 and c.id = d.wsid1 where not a.boundary group by 1 having count (d.id) = 0;
--Then, use list of disconnected watersheds to populate exit points.
--To maintain requirement that each child have a 1-dimensional interface with its parent, the parentIDs are set to null,
--and the exit point chosen is the closest approach between the child and all possible parents from the original dataset.
--This must be finished before a cycle looking at parent geometries, because some ambiguous watersheds descend from detached roots.
insert into _exitpoints select a.id, null, st_closestpoint (b.mercgeom, c.mercgeom) from (
	select distinct a.id, first_value(d.id) over (partition by a.id order by st_distance(a.mercgeom, d.mercgeom), d.id) as parentid
	from wdws a left join _exitpoints b on a.id = b.id inner join wbdhu12 c on a.externalid = c.id
	inner join wdws d on c.parentid = d.externalid inner join _disconnectedwatersheds e on a.id = e.id where b.id is null
) a inner join wdws b on a.id = b.id inner join wdws c on a.parentid = c.id;

--Find point on each interface which is closest to parent exit point for remainder of polygons.
set @lastcount = 0; set @thiscount = 1;
while @lastcount < @thiscount begin
	select raisenotice(now()::text || ' - Finding parents and exit points. Last count: @lastcount.  Current count: @thiscount');
	insert into _exitpoints select a.id, a.parentid, st_closestpoint(a.mercgeom, a.exitmercgeom) from (
		select distinct a.id, 
		first_value(d.id) over (partition by a.id order by st_distance(e.mercgeom, f.mercgeom), st_length(f.mercgeom) desc, d.id) as parentid,
		first_value(f.mercgeom) over (partition by a.id order by st_distance(e.mercgeom, f.mercgeom), st_length(f.mercgeom) desc, d.id) as mercgeom,
		first_value(e.mercgeom) over (partition by a.id order by st_distance(e.mercgeom, f.mercgeom), st_length(f.mercgeom) desc, d.id) as exitmercgeom
		from wdws a left join _exitpoints b on a.id = b.id inner join wbdhu12 c on a.externalid = c.id
		inner join wdws d on c.parentid = d.externalid inner join _exitpoints e on d.id = e.id
		inner join wdwsconnections f on a.id = f.wsid0 and d.id = f.wsid1 where b.id is null
	) a order by 1;
	set @lastcount = @thiscount;
	set @thiscount = select count(*) from _exitpoints; set @thiscount = @thiscount[0][0];
end

--Back-populate parentIDs and exit points.
update wdws set parentid = null;
update wdws a set parentid = b.parentid, exitmercgeom = b.mercgeom from _exitpoints b where a.id = b.id;

--Testing for cyclical descents. This should generate 4 identical numbers. Roughly 30 seconds for deeply-nested 100k rows.
/*
with recursive ws(id, parentid, path) as (
	select id, parentid, array[id] from wdws where parentid is null
union all
	select b.id, b.parentid, a.path || b.id from ws a inner join wdws b on a.id = b.parentid where not b.id = any(a.path)
) select count(*), count(distinct id) from ws union all select count(*), count(distinct id) from wdws;

--Creates river structure
drop table if exists wdrivers; select a.id, a.parentid, a.stateid, st_makeline(a.exitmercgeom, b.exitmercgeom) as mercgeom into wdrivers from wdws a inner join wdws b on a.parentid = b.id
--Add leaf descents.  This makes ID not unique...
union all select a.id, a.id, a.stateid, st_makeline(st_centroid(a.mercgeom), a.exitmercgeom) from wdws a left join wdws b on b.parentid = a.id where b.id is null order by 1,2;
*/


-------------------------------------------
--8. Connect Non-Contiguous Polygon Groups
-------------------------------------------
--Connect islands together into tree.  This identifies connexions between watersheds, not merely islands. 50 min.
--If you don't do this with geographies, you will get different results! Far-off island chains like Hawai'i and Guam are actually closest to Alaska, not the mainland.
select raisenotice(now()::text || ' - Connect Non-Contiguous Polygon Groups.');

--This table should be identical to the _connectedsegments table from adjacency network calculation above.
--If running the table in a single batch, this does not need to be recalculated.
drop table if exists _connectedsegments;
select a.id as id0, a.wsid as wsid0, a.ordinal as ordinal0, coalesce(b.id, 0) as id1, coalesce(b.wsid, 0) as wsid1, coalesce(b.ordinal, 0) as ordinal1,
	st_length(a.mercgeom) as thelength into temp _connectedsegments from (select * from wdwssegments order by x0, y0, x1, y1) a
left join (select * from wdwssegments order by x1, y1, x0, y0) b on a.x0 = b.x1 and a.y0 = b.y1 and a.x1 = b.x0 and a.y1 = b.y0 and a.stateid = b.stateid order by 2, 3;
select raisenotice(now()::text || ' - Done connected segments.');

--Generate geographies for boundary lines per polygon.
drop table if exists _islandareas; select islandid as id, sum(st_area(st_transform(mercgeom, 4326)::geography)) as thearea into temp _islandareas
from wdws group by 1 order by 1;
drop table if exists _boundarysegments; select a.wsid, a.stateid, a.islandid, a.islandid as islandtreeid, b.thearea, st_transform(st_centroid(a.mercgeom), 4326)::geography as centroidgeog,
	st_transform(a.mercgeom, 4326)::geography as thegeog into temp _boundarysegments
from (select a.wsid, a.islandid, a.stateid, geom(st_dump(a.mercgeom)) as mercgeom from (
	select b.wsid, c.islandid, c.stateid, st_linemerge(st_collect(b.mercgeom)) as mercgeom
	from (select id0 from _connectedsegments where wsid1 = 0 order by 1) a
	inner join wdwssegments b on a.id0 = b.id inner join wdws c on b.wsid = c.id group by 3, 2, 1 order by 3, 2, 1 desc
) a ) a inner join _islandareas b on a.islandid = b.id;
create index ix__boundarysegments_centroidgeog on _boundarysegments using gist(centroidgeog);
create index ix__boundarysegments_thegeog on _boundarysegments using gist(thegeog);
drop table if exists _permanentislandconnections; create temp table _permanentislandconnections (wsid0 int, wsid1 int);
drop table if exists _islanddistances; create temp table _islanddistances (islandtreeid int, thedistance double precision);

--Start loop here.  Stop when no state has more than a single island tree.
while (select 1 from _boundarysegments group by stateid having count(distinct islandtreeid) > 1 limit 1) begin
	select raisenotice(now()::text || ' - Islands left: ' || (select count(distinct islandtreeid) from _boundarysegments)::varchar);
	--Default tolerance to smallest previous distance
	if (select 1 from _islanddistances limit 1) begin
		set @tolerance = (select min(thedistance) from _islanddistances); set @tolerance = cast (@tolerance[0][0] as real);
	end else begin
		set @tolerance = 1024.0;
	end
	drop table if exists _islandconnections; create temp table _islandconnections (islandtreeid0 int, islandtreeid1 int, wsid0 int, wsid1 int);
	--Only match to segments in states that aren't already 100% connected.
	drop table if exists _matchsegments; select a.* into temp _matchsegments from _boundarysegments a
	inner join (select stateid from _boundarysegments group by stateid having count(distinct islandtreeid) > 1) b on a.stateid = b.stateid;
	truncate _islanddistances;
	while (select 1 from _matchsegments limit 1) begin
		select raisenotice(now()::text || ' - Tolerance: @tolerance');
		insert into _islanddistances select a.islandtreeid, st_distance(a.thegeog0, a.thegeog1) + 1 from (
			select distinct a.islandtreeid, 
				first_value(a.thegeog) over (partition by a.islandtreeid order by st_distance(a.centroidgeog, b.centroidgeog)) as thegeog0,
				first_value(b.thegeog) over (partition by a.islandtreeid order by st_distance(a.centroidgeog, b.centroidgeog)) as thegeog1
			from _matchsegments a, _boundarysegments b where st_dwithin(a.centroidgeog, b.centroidgeog, @tolerance) and a.islandtreeid != b.islandtreeid
				and a.stateid = b.stateid
		) a;
		delete from _matchsegments a using _islanddistances b where a.islandtreeid = b.islandtreeid;
		set @tolerance = @tolerance * 2;
	end
	select raisenotice(now()::text || ' - Start segment match');
	--Once the closest polygon distance between the closest centroids has been identified, this can be used to scan all polygons with overlapping bounding boxes.
	insert into _islandconnections(islandtreeid0, islandtreeid1, wsid0, wsid1) select distinct a.islandtreeid,
	first_value(b.islandtreeid) over (partition by a.islandtreeid order by st_distance(a.thegeog, b.thegeog), b.thearea desc, b.wsid),
	first_value(a.wsid) over (partition by a.islandtreeid order by st_distance(a.thegeog, b.thegeog), b.thearea desc, b.wsid),
	first_value(b.wsid) over (partition by a.islandtreeid order by st_distance(a.thegeog, b.thegeog), b.thearea desc, b.wsid)
	from _islanddistances c inner join _boundarysegments a on a.islandtreeid = c.islandtreeid
		inner join _boundarysegments b on st_dwithin(a.thegeog, b.thegeog, c.thedistance) where a.islandtreeid != b.islandtreeid and a.stateid = b.stateid;
	--Generate reciprocal tree IDs:
	drop table if exists _reciprocalislandtrees; select islandtreeid0, islandtreeid1 into temp _reciprocalislandtrees
	from _islandconnections union select islandtreeid1, islandtreeid0 from _islandconnections;
	--Repeat until each tree matches back to its lowest connecting ID:
	while (
		select 1 from (
			select a.islandtreeid0, min(b.islandtreeid1) as islandtreeid1 from _reciprocalislandtrees a inner join _reciprocalislandtrees b on a.islandtreeid1 = b.islandtreeid0 group by 1 order by 1
		) a inner join (
			select islandtreeid0, min(islandtreeid1) as islandtreeid1 from _reciprocalislandtrees group by 1 order by 1
		) b on a.islandtreeid0 = b.islandtreeid0 where a.islandtreeid1 < b.islandtreeid1 limit 1
	) begin
		insert into _reciprocalislandtrees select a.* from (
			select a.islandtreeid0, min(b.islandtreeid1) as islandtreeid1 from _reciprocalislandtrees a inner join _reciprocalislandtrees b on a.islandtreeid1 = b.islandtreeid0 group by 1 order by 1
		) a inner join (
			select islandtreeid0, min(islandtreeid1) as islandtreeid1 from _reciprocalislandtrees group by 1 order by 1
		) b on a.islandtreeid0 = b.islandtreeid0 where a.islandtreeid1 < b.islandtreeid1;
	end
	--Save watershed connexions in permanent table and truncate cycle table
	insert into _permanentislandconnections select wsid0, wsid1 from _islandconnections; truncate _islandconnections;
	--Update island tree in segment data
	update _boundarysegments a set islandtreeid = b.islandtreeid1
	from (select islandtreeid0, min(islandtreeid1) as islandtreeid1 from _reciprocalislandtrees group by 1 order by 2) b where a.islandtreeid = b.islandtreeid0;
end
--Make permanent.
drop table if exists wdwsislandconnections; create table wdwsislandconnections(wsid0 int, wsid1 int, islandid0 int, islandid1 int);
insert into wdwsislandconnections(wsid0, wsid1, islandid0, islandid1) select a.wsid0, a.wsid1, b.islandid as islandid0, c.islandid as islandid1
from (select wsid0, wsid1 from _permanentislandconnections union select wsid1, wsid0 from _permanentislandconnections) a
inner join wdws b on a.wsid0 = b.id inner join wdws c on a.wsid1 = c.id order by 1,2;
--Some watersheds are precisely the same distance away, resulting in multiple connexions between the same islands.  These are only cases where island ID 0 < island ID 1.
--Select pairs with closest geographic center.
delete from wdwsislandconnections a using (
	select distinct a.islandid0, a.islandid1,
	first_value(a.wsid0) over (partition by a.islandid0, a.islandid1 order by a.thedistance, a.wsid0, a.wsid1) as wsid0,
	first_value(a.wsid1) over (partition by a.islandid0, a.islandid1 order by a.thedistance, a.wsid0, a.wsid1) as wsid1
	from (
		select b.*, st_distance(st_transform(st_centroid(c.mercgeom), 4326)::geography, st_transform(st_centroid(d.mercgeom), 4326)::geography) as thedistance
		from (select islandid0, islandid1 from wdwsislandconnections where islandid0 < islandid1 group by 1,2 having count(*) > 1) a
		inner join wdwsislandconnections b on a.islandid0 = b.islandid0 and a.islandid1 = b.islandid1 
		inner join wdws c on b.wsid0 = c.id inner join wdws d on b.wsid1 = d.id
	) a
) b where a.islandid0 = b.islandid0 and a.islandid1 = b.islandid1 and (a.wsid0 != b.wsid0 or a.wsid1 != b.wsid1);
--Remove anyone where there is no reciprocal.
delete from wdwsislandconnections a using (
	select a.* from wdwsislandconnections a left join wdwsislandconnections b on a.wsid0 = b.wsid1 and a.wsid1 = b.wsid0 where b.wsid0 is null
) b where a.wsid0 = b.wsid0 and a.wsid1 = b.wsid1;

/*
--Make "island rivers":
drop table if exists wdrivers; select a.wsid0, a.wsid1, b.stateid, st_makeline(b.exitmercgeom, c.exitmercgeom) as mercgeom into wdrivers
from wdwsislandconnections a inner join wdws b on a.wsid0 = b.id inner join wdws c on a.wsid1 = c.id;
*/


------------------------
--9. Process Census Data
------------------------
--Define island ID and boundary for each census block, and connect non-contiguous census blocks at closest geographical approach.  This is a simplified version of the process used on watersheds above.
--Should only need one point from each block to identify island.
select raisenotice(now()::text || ' - Process Census Data.');
drop table if exists _cbpoints; select id, stateid, st_startpoint(st_exteriorring(st_geometryn(mercgeom, 1)))::geometry(point, 3857) as mercgeom into temp _cbpoints from wdcensusblocks;
create index ix__cbpoints_mercgeom on _cbpoints using gist(mercgeom);
drop table if exists _islands; create temp table _islands (id serial primary key, stateid int, mercgeom geometry(polygon, 3857));
insert into _islands (stateid, mercgeom) select stateid, geom(st_dump(mercgeom)) as mercgeom from wdcensusstates; create index ix__islands_mercgeom on _islands using gist(mercgeom);
drop table if exists _blockislands; select a.id as blockid, b.id as islandid into temp _blockislands from _cbpoints a inner join _islands b on a.stateid = b.stateid and st_intersects(a.mercgeom, b.mercgeom);
--Sanity check, should be 4 identical: select count(*), count(distinct blockid) from _blockislands union all select count(*), count(distinct id) from wdcensusblocks;

--Dump subset of border points from state boundaries to identify border polygons.
drop table if exists _borderpoints; create temp table _borderpoints (stateid int, mercgeom geometry(point, 3857));
insert into _borderpoints (stateid, mercgeom) select stateid, geom(st_dumppoints(mercgeom)) as mercgeom from wdcensusstates; create index ix__borderpoints_mercgeom on _borderpoints using gist(mercgeom);
--This table is used with nearest neighbour queries to find closest approach to each island group.
drop table if exists _censusblockboundaries; create temp table _censusblockboundaries (id int primary key, stateid int, islandid int, groupid int, thegeog geography(multipolygon, 4326)); alter table _censusblockboundaries alter column thegeog set storage external;
insert into _censusblockboundaries select b.id, b.stateid, c.islandid, c.islandid, st_transform(b.mercgeom, 4326)::geography from (
	select distinct a.id as blockid from wdcensusblocks a inner join _borderpoints b on st_intersects(a.mercgeom, b.mercgeom) and a.stateid = b.stateid
) a inner join wdcensusblocks b on a.blockid = b.id inner join _blockislands c on a.blockid = c.blockid order by a.blockid;
create index ix__censusblockboundaries_thegeog on _censusblockboundaries using gist(thegeog);
drop table if exists _islands; select distinct stateid, islandid, islandid as groupid into temp _islands from _censusblockboundaries;
drop table if exists _islandconnections; select stateid, id as blockid0, id as blockid1, islandid as islandid0, islandid as islandid1 into temp _islandconnections from wdcensusblocks where 0=1;

--Connect groups until there is only one per state.
while (select 1 where (select count(distinct groupid) from _islands) > (select count(distinct stateid) from _islands)) begin
	--Create rough point outline of states with one point per block.
	drop table if exists _pointboundarygroups; create temp table _pointboundarygroups (groupid int primary key, stateid int, mercgeom geometry(multipoint, 3857)); alter table _pointboundarygroups alter column mercgeom set storage external;
	insert into _pointboundarygroups select groupid, stateid, st_transform(st_collect(st_startpoint(st_exteriorring(st_geometryn(thegeog::geometry, 1)))), 3857) as mercgeom from _censusblockboundaries group by 2, 1 order by 2, 1;
	create index ix__pointboundarygroups_mercgeom on _pointboundarygroups using gist(mercgeom);
	--By using a lateral join with a closest proximity fuzzy limiter, it's possible to locate a hard optimised geographic lower bound to limit the processing on the actual geography proximity.
	drop table if exists _closestgroups; select a.groupid as groupid0, b.groupid as groupid1, st_distance(st_transform(a.mercgeom, 4326)::geography, st_transform(b.mercgeom, 4326)::geography) as thedistance
	into temp _closestgroups from _pointboundarygroups a cross join lateral (select * from _pointboundarygroups b where a.groupid != b.groupid and a.stateid = b.stateid order by a.mercgeom <#> b.mercgeom limit 1) b;
	--Generate actual list of closest block connexions.
	insert into _islandconnections (stateid, blockid0, blockid1) select distinct a.stateid,
	first_value(a.id) over (partition by a.groupid order by st_distance(a.thegeog, c.thegeog), least(st_area(a.thegeog), st_area(c.thegeog)), greatest(st_area(a.thegeog), st_area(c.thegeog))) as blockid0,
	first_value(c.id) over (partition by a.groupid order by st_distance(c.thegeog, a.thegeog), least(st_area(a.thegeog), st_area(c.thegeog)), greatest(st_area(a.thegeog), st_area(c.thegeog))) as blockid1
	from _censusblockboundaries a inner join _closestgroups b on a.groupid = b.groupid0 inner join _censusblockboundaries c on st_dwithin(a.thegeog, c.thegeog, b.thedistance + 1)
	where a.groupid != c.groupid and a.stateid = c.stateid;
	--Add to island connections.
	update _islandconnections a set islandid0 = b.islandid, islandid1 = c.islandid from _censusblockboundaries b, _censusblockboundaries c where a.blockid0 = b.id and a.blockid1 = c.id;
	--Add any missing reciprocals.
	insert into _islandconnections (stateid, blockid0, blockid1, islandid0, islandid1) select a.stateid, a.blockid1, a.blockid0, a.islandid1, a.islandid0
	from _islandconnections a left join _islandconnections b on a.blockid0 = b.blockid1 and a.blockid1 = b.blockid0 where b.blockid0 is null;
	--Harmonise groups to lowest group ID.
	while (select 1 from _islandconnections a inner join _islands b on a.islandid0 = b.islandid inner join _islands c on a.islandid1 = c.islandid where c.groupid < b.groupid) begin
		update _islands a set groupid = b.groupid from (
			select b.islandid, min(c.groupid) as groupid from _islandconnections a inner join _islands b on a.islandid0 = b.islandid inner join _islands c on a.islandid1 = c.islandid where c.groupid < b.groupid group by 1
		) b where a.islandid = b.islandid;
	end
	--Back-populate boundary geography groups.
	update _censusblockboundaries a set groupid = b.groupid from _islands b where a.islandid = b.islandid;
end

--Export to permanent table.
drop table if exists wdcensusblockislandconnections; create table wdcensusblockislandconnections (id serial primary key, stateid int, blockid0 int, blockid1 int, islandid0 int, islandid1 int, mercgeom geometry(linestring, 3857));
insert into wdcensusblockislandconnections (stateid, blockid0, blockid1, islandid0, islandid1, mercgeom) select a.*, st_makeline(st_centroid(b.mercgeom), st_centroid(c.mercgeom)) as mercgeom
from _islandconnections a inner join wdcensusblocks b on a.blockid0 = b.id inner join wdcensusblocks c on a.blockid1 = c.id;

--Update census block boundary and island ID.  Up to 1 hour.
update wdcensusblocks a set islandid = b.islandid, boundary = b.boundary from (
	select a.blockid, a.islandid, b.id is not null as boundary from _blockislands a left join _censusblockboundaries b on a.blockid = b.id order by a.blockid
) b where a.id = b.blockid;

--Create census block network.  Find all neighbours to all census blocks... 7 hours.  This is required for PHP processing later.
drop table if exists wdcensusblockconnections; create table wdcensusblockconnections (id serial primary key, blockid0 int, blockid1 int);
insert into wdcensusblockconnections (blockid0, blockid1) select a.id, b.id from wdcensusblocks a, wdcensusblocks b
where st_relate(a.mercgeom, b.mercgeom, '****1****') and a.mercgeom && b.mercgeom and a.id != b.id order by 1,2;

--Generate population distribution from actual census base data.  At this point, the polygons should not be changing anymore, and may be used to determine populations.
--Connect populations using census data. Carve up census blocks using watersheds.  4 hours for initial match. 8 hours total.
--Temporary area overlap table.  Contains intersection between each census block and each watershed that overlap.
drop table if exists _censuswsoptions; select a.id as blockid, b.id as wsid, a.stateid as censusstateid, b.stateid as wsstateid, st_area(st_intersection(a.mercgeom, b.mercgeom)) as thearea
into temp _censuswsoptions from wdcensusblocks a, wdws b where st_intersects(a.mercgeom, b.mercgeom) order by 1,2;

--Permanent table. BlockID is unique.
drop table if exists wdcensusws; create table wdcensusws (blockid int primary key, wsid int);
insert into wdcensusws (blockid, wsid) select distinct a.blockid, first_value(a.wsid) over (partition by a.blockid order by a.thearea desc, a.wsid) as wsid from _censuswsoptions a where a.censusstateid = a.wsstateid;

--Grab stragglers who don't overlap and connect them to closest watershed.
--These cannot simply be used in place of the watershed geometries, because many polygons are over water.
drop table if exists _stragglers; select a.* into temp _stragglers from wdcensusblocks a left join wdcensusws b on a.id = b.blockid where b.blockid is null;

--Connect remainder to closest watershed.  Doing this in 3 passes is significantly faster.  First one is at 10k tolerance.
insert into wdcensusws select distinct a.id, first_value(b.id) over (partition by a.id order by st_distance(a.mercgeom, b.mercgeom), b.id)
from _stragglers a, wdws b where st_dwithin(a.mercgeom, b.mercgeom, 10000)
	and ((select count(distinct stateid) from wdws) = 1 or a.stateid = b.stateid);

--Delete matched stragglers
delete from _stragglers a using wdcensusws b where a.id = b.blockid;

--2nd pass is at 100k
insert into wdcensusws select distinct a.id, first_value(b.id) over (partition by a.id order by st_distance(a.mercgeom, b.mercgeom), b.id)
from _stragglers a, wdws b where st_dwithin(a.mercgeom, b.mercgeom, 100000)
	and ((select count(distinct stateid) from wdws) = 1 or a.stateid = b.stateid);

--Delete matched stragglers
delete from _stragglers a using wdcensusws b where a.id = b.blockid;

--Final pass is at 2M.  This grabs everything that's left
insert into wdcensusws select distinct a.id, first_value(b.id) over (partition by a.id order by st_distance(a.mercgeom, b.mercgeom), b.id)
from _stragglers a, wdws b where st_dwithin(a.mercgeom, b.mercgeom, 2200000)
	and ((select count(distinct stateid) from wdws) = 1 or a.stateid = b.stateid);

--Should be unique now.
create unique index ix_wdcensusws_blockid on wdcensusws using btree(blockid);

--Consistency test, should be equal: select count(*), count(distinct blockid) from wdcensusws union all select count(*), count(distinct id) from wdcensusblocks;

--Sum populations into watersheds
update wdws a set population = b.totalpopulation from (
	select a.wsid, sum(b.population) as totalpopulation from wdcensusws a inner join wdcensusblocks b on a.blockid = b.id group by 1
) b where a.id = b.wsid;

--update unpopulated watersheds
update wdws set population = 0 where population is null;

--Consistency test. If all states are included, these should be identical: select sum(population) from wdws union all select sum(population) from wdcensusblocks;
--True district size for 435 equal districts: 709760. select round(sum(population) / 435.0) from wdws;

select raisenotice(now()::text || ' - END SQL BATCH PROCESS.');
--END SQL BATCH PROCESS.


--------------------
--10. PHP processing
--------------------
--Run basinconnector.php then trimtrees.php.
--These could be merged into a single file, but connecting the basins can take several hours and only needs to be done once.
--To fine-tune the output of the trimtrees function, it makes more sense to stage the processing.


-------------------------------------
--11. Data export and post-processing
-------------------------------------
/*
--Generates merged census block polygons grouped by state and district if not already created by trimtrees.php.
drop table if exists wddistricts; select b.stateid, a.districtid, sum(b.population) as population, st_unaryunion(st_collect(b.mercgeom)) as mercgeom into wddistricts
from wddistrictblocks a inner join wdcensusblocks b on a.id = b.id group by 1,2 order by 1,2;
*/

--Export geometries to KML and/or text. KML files become too large for clients to render very easily.  Only one state may be exported at a time.  PGScript.
set @state = 'California';
set @stateid = (select stateid from wdcensusstates where name = '@state');
set @stateid = @stateid[0][0];

--Export district definitions by full 15 character census block identifier; state, county, census tract and tabulation block.
--copy (select a.districtid, b.blockid10 from wddistrictblocks a inner join wdcensusblocks b on a.id = b.id where b.stateid = @stateid order by 1,2) to '/tmp/@state-Districts.txt' with csv header;

copy (select '<?xml version="1.0" encoding="UTF-8"?><kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2" xmlns:kml="http://www.opengis.net/kml/2.2" xmlns:atom="http://www.w3.org/2005/Atom">'
|| '<Document><name>@state District Map</name><open>1</open>'
--Default
|| '<StyleMap id="default"><Pair><key>normal</key><styleUrl>#sndefault</styleUrl></Pair><Pair><key>highlight</key><styleUrl>#shdefault</styleUrl></Pair></StyleMap>'
|| '<Style id="sndefault"><IconStyle><color>ffffffff</color><scale>0.8</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>'
|| '<LineStyle><color>FF0000FF</color><width>3</width></LineStyle><PolyStyle><color>00000000</color><outline>1</outline><fill>0</fill></PolyStyle>'
|| '<BalloonStyle><text><![CDATA[<style>th, td {padding:0px 0px 0px 12px;text-indent:-12px;text-align:left;vertical-align:top;}</style><table><tr><th>$[name]</th></tr>$[description]</table>]]></text></BalloonStyle>'
|| '<LabelStyle><scale>1</scale></LabelStyle><ListStyle></ListStyle></Style>'
|| '<Style id="shdefault"><IconStyle><color>ffffffff</color><scale>0.8</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>'
|| '<LineStyle><color>FF0000FF</color><width>3</width></LineStyle><PolyStyle><color>00000000</color><outline>1</outline><fill>0</fill></PolyStyle>'
|| '<BalloonStyle><text><![CDATA[<style>th, td {padding:0px 0px 0px 12px;text-indent:-12px;text-align:left;vertical-align:top;}</style><table><tr><th>$[name]</th></tr>$[description]</table>]]></text></BalloonStyle>'
|| '<LabelStyle><scale>1</scale></LabelStyle><ListStyle></ListStyle></Style>'
--Label style
|| '<StyleMap id="label"><Pair><key>normal</key><styleUrl>#snlabel</styleUrl></Pair><Pair><key>highlight</key><styleUrl>#shlabel</styleUrl></Pair></StyleMap>'
|| '<Style id="snlabel"><IconStyle><color>ffffffff</color><scale>0.8</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>'
|| '<LineStyle><color>FF0000FF</color><width>3</width></LineStyle><PolyStyle><color>00000000</color><outline>1</outline><fill>0</fill></PolyStyle>'
|| '<BalloonStyle><text><![CDATA[<style>th, td {padding:0px 0px 0px 12px;text-indent:-12px;text-align:left;vertical-align:top;}</style><table><tr><th>District $[name]</th></tr>$[description]</table>]]></text></BalloonStyle>'
|| '<LabelStyle><scale>1</scale></LabelStyle><ListStyle></ListStyle></Style>'
|| '<Style id="shlabel"><IconStyle><color>ffffffff</color><scale>0.8</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>'
|| '<LineStyle><color>FF0000FF</color><width>3</width></LineStyle><PolyStyle><color>00000000</color><outline>1</outline><fill>0</fill></PolyStyle>'
|| '<BalloonStyle><text><![CDATA[<style>th, td {padding:0px 0px 0px 12px;text-indent:-12px;text-align:left;vertical-align:top;}</style><table><tr><th>District $[name]</th></tr>$[description]</table>]]></text></BalloonStyle>'
|| '<LabelStyle><scale>1</scale></LabelStyle><ListStyle></ListStyle></Style>'
--River style
|| '<StyleMap id="river"><Pair><key>normal</key><styleUrl>#snriver</styleUrl></Pair><Pair><key>highlight</key><styleUrl>#shriver</styleUrl></Pair></StyleMap>'
|| '<Style id="snriver"><IconStyle><color>ffffffff</color><scale>0.5</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>'
|| '<LineStyle><color>FFFFFF00</color><width>1</width></LineStyle><PolyStyle><color>00000000</color><outline>1</outline><fill>0</fill></PolyStyle>'
|| '<BalloonStyle><text><![CDATA[<style>th, td {padding:0px 0px 0px 12px;text-indent:-12px;text-align:left;vertical-align:top;}</style><table><tr><th>$[name]</th></tr></table>$[description]]]></text></BalloonStyle>'
|| '<LabelStyle><scale>1</scale></LabelStyle><ListStyle></ListStyle></Style>'
|| '<Style id="shriver"><IconStyle><color>ffffffff</color><scale>0.5</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>'
|| '<LineStyle><color>FFFFFF00</color><width>1</width></LineStyle><PolyStyle><color>00000000</color><outline>1</outline><fill>0</fill></PolyStyle>'
|| '<BalloonStyle><text><![CDATA[<style>th, td {padding:0px 0px 0px 12px;text-indent:-12px;text-align:left;vertical-align:top;}</style><table><tr><th>$[name]</th></tr></table>$[description]]]></text></BalloonStyle>'
|| '<LabelStyle><scale>1</scale></LabelStyle><ListStyle></ListStyle></Style>'
--watershed style
|| '<StyleMap id="ws"><Pair><key>normal</key><styleUrl>#snws</styleUrl></Pair><Pair><key>highlight</key><styleUrl>#shws</styleUrl></Pair></StyleMap>'
|| '<Style id="snws"><IconStyle><color>ffffffff</color><scale>0.5</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>'
|| '<LineStyle><color>FFFFCCCC</color><width>1</width></LineStyle><PolyStyle><color>00000000</color><outline>1</outline><fill>0</fill></PolyStyle>'
|| '<BalloonStyle><text><![CDATA[<style>th, td {padding:0px 0px 0px 12px;text-indent:-12px;text-align:left;vertical-align:top;}</style><table><tr><th>$[name]</th></tr></table>$[description]]]></text></BalloonStyle>'
|| '<LabelStyle><scale>1</scale></LabelStyle><ListStyle></ListStyle></Style>'
|| '<Style id="shws"><IconStyle><color>ffffffff</color><scale>0.5</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>'
|| '<LineStyle><color>FFFFCCCC</color><width>1</width></LineStyle><PolyStyle><color>00000000</color><outline>1</outline><fill>0</fill></PolyStyle>'
|| '<BalloonStyle><text><![CDATA[<style>th, td {padding:0px 0px 0px 12px;text-indent:-12px;text-align:left;vertical-align:top;}</style><table><tr><th>$[name]</th></tr></table>$[description]]]></text></BalloonStyle>'
|| '<LabelStyle><scale>1</scale></LabelStyle><ListStyle></ListStyle></Style>'
--Labels
union all select '<Folder><open>0</open><name>Labels</name>'
union all select '<Placemark><name>' || districtid::varchar || '</name><Snippet></Snippet><description><tr><td>Population: ' || trim(to_char(population, '999,999,999,999'))
	|| '</td></tr></description><styleUrl>#label</styleUrl>' || st_askml(st_transform(st_centroid(mercgeom), 4326)) || '</Placemark>'
from (select * from wddistricts where stateid = @stateid order by districtid) a
union all select '</Folder>'

/*
--Hopefully, these sections will help people get a sense for what the project is attempting to accomplish and why the districts make logical sense.
--They cause the output file to be much larger.
--Rivers.
union all select '<Folder><open>0</open><name>Rivers</name>'
union all select '<Placemark><name>River</name><Snippet></Snippet><description></description><styleUrl>#river</styleUrl>' || st_askml(st_transform(a.mercgeom, 4326)) || '</Placemark>'
from wdrivers a inner join wdws b on a.id = b.id where b.stateid = @stateid
union all select '</Folder>'
--Watersheds.
union all select '<Folder><open>0</open><name>Watersheds</name>'
union all select '<Placemark><name>WS</name><Snippet></Snippet><description></description><styleUrl>#ws</styleUrl>' || st_askml(st_transform(mercgeom, 4326)) || '</Placemark>' from wdws where stateid = @stateid
union all select '</Folder>'
*/

--District polygons.
union all select '<Folder><open>1</open><name>Districts</name>'
union all select '<Placemark><name>District ' || districtid::varchar || '</name><Snippet>Population: ' || trim(to_char(population, '999,999,999,999'))
	|| '</Snippet><description><tr><td>Population: ' || trim(to_char(population, '999,999,999,999'))
	|| '</td></tr></description><styleUrl>#default</styleUrl>' || st_askml(st_transform(mercgeom, 4326)) || '</Placemark>'
from (select * from wddistricts where stateid = @stateid order by districtid) a
union all select '</Folder></Document></kml>') to program 'sed ''s/\\t/\t/g'' | sed ''s/\\n/\n/g'' > /tmp/doc.kml && cd /tmp && zip -m @state-Districts.kmz doc.kml && chmod 644 @state-Districts.kmz';

/*
--Miscellaneous consistency checks

--Testing for cyclical descents. This should generate 4 identical numbers. Roughly 30 seconds for deeply-nested 100k rows.
with recursive ws(id, parentid, path) as (
	select id, parentid, array[id] from wdwstree where parentid is null
union all
	select b.id, b.parentid, a.path || b.id from ws a inner join wdwstree b on a.id = b.parentid where not b.id = any(a.path)
) select count(*), count(distinct id) from ws union all select count(*), count(distinct id) from wdwstree;

--Creates river-like structure to visualise entire tree:
drop table if exists wdrivers; select a.id, a.parentid, a.stateid, st_makeline(b.exitmercgeom, c.exitmercgeom) as mercgeom into wdrivers from wdwstree a inner join wdws b on a.id = b.id inner join wdws c on a.parentid = c.id
--Add leaf descents.  This makes ID not unique...
union all select a.id, a.id, a.stateid, st_makeline(st_centroid(a.mercgeom), c.exitmercgeom) from wdwstree a left join wdwstree b on b.parentid = a.id inner join wdws c on a.id = c.id where b.id is null order by 1,2;

--Optional tool for visualising basins.
drop table if exists wdbasins; create table wdbasins(id int primary key, stateid int, population int, mercgeom geometry(polygon, 3857)); alter table wdbasins alter column mercgeom set storage external;
insert into wdbasins select basinid, stateid, sum(population) as population, st_unaryunion(st_collect(mercgeom)) as mercgeom from wdws group by 1, 2 order by stateid, basinid;

--Finds out where basins have been connected.
select b.id, b.parentid, st_makeline(b.exitmercgeom, c.exitmercgeom) as mercgeom from wdwstree a inner join wdws b on a.id = b.id inner join wdws c on a.parentid = c.id where b.basinid != c.basinid;

--Finds flow reversals.
select b.id, b.parentid, st_makeline(b.exitmercgeom, c.exitmercgeom) as mercgeom from
wdwstree a inner join wdws b on a.id = b.id inner join wdws c on a.parentid = c.id inner join wdws d on a.id = d.parentid and a.parentid = d.id;

*/
