<?php
//Common include file.  Tested with Ubuntu 18.04 LTS, PHP 7.2 and PostGIS 2.5.

/*

v3.1 major changes:

*Uses actual census block geometries to create districts instead of deferring division of watersheds to a later time.
*Uses squared, advancing edge to determine limit of district.
*The exit points for watersheds are now determined by actual river and lake geometries.

*/

//--------------------------------
//Constants
const VERSION = 3.1;
define ('connectionstring', 'host=localhost dbname=db user=username password=password');

//--------------------------------
//Classes
//Should encapsulate construction/destruction plus allow function calls of arbitrary length.
//Sourced and updated from http://pgedit.com/resource/php/pgfuncall
class dbconnection {
	private $prepared = array();
	//I'm making the connexion public so I don't have to create a new one to access batch copy functions.  Not sure if this will disallow functions named "connection".
	public $connection;

	function __construct($connectionstring) {
		if (is_string($connectionstring)) $this->connection = pg_connect($connectionstring);
		else $this->connection = $connectionstring;
	}

	// Kill all the prepared statements.
	function __destruct() {
		foreach($this->prepared as $statement) {
			$result = pg_query($this->connection, 'deallocate '  . $statement);
		}
	}

	// The __call magic method is called whenever an unknown method for the instance is called.
	function __call($fname, $fargs) {
		$statement = $fname . '__' . count($fargs);
		if (!in_array($statement, $this->prepared)) { // first time, not prepared yet
			$alist = array();
			for($i = 0; $i < count($fargs); $i++) {
				$alist[$i] = '$' . ($i + 1);
				//Okay, so if the arg is not null, and it's a boolean value, send in 't' or 'f'.  Postgres requirement.
				if ($fargs[$i] !== null)
					if (gettype($fargs[$i]) == 'boolean')
						$fargs[$i] = $fargs[$i]?'t':'f';
			}
			$sql = 'select * from ' . $fname . '(' . implode(',', $alist) . ')';
			$prep = pg_prepare($this->connection, $statement, $sql);
			$this->prepared[] = $statement;
		}
		if ($res = pg_execute($this->connection, $statement, $fargs)) {
			$rows = pg_num_rows($res);
			$cols = pg_num_fields($res);
			if ($cols > 1) return $res; // return the cursor if more than 1 col
			else if ($rows == 0) return null;
			else if ($rows == 1) return pg_fetch_result($res, 0); // single result
			else return pg_fetch_all_columns($res, 0); // get column as an array
		}
	}

	//If you need to just execute a query
	function execute ($sql) {
		if ($res = pg_query($this->connection, $sql)) {
			$rows = pg_num_rows($res);
			$cols = pg_num_fields($res);
			if ($cols > 1) return $res; // return the cursor if more than 1 col
			else if ($rows == 0) return null;
			else if ($rows == 1) return pg_fetch_result($res, 0); // single result
			else return pg_fetch_all_columns($res, 0); // get column as an array
		}
	}
}

//--------------------------------
//Globals
//Always opens a DB connexion...
$currentdb = new dbconnection(connectionstring);

//--------------------------------
//Data manipulation functions

//Avoids notices in strict reporting systems.  Request encapsulation.
function request($value) {
	if (isset($_REQUEST[$value]))
		return ($_REQUEST[$value]);
	else
		return (null);
}

//UTF-8 to integer. If you send this 88. versus "88.", the first will give you the integer, and the second won't. String input is treated more harshly than numbers already cast as int. Values that exceed int4 will give null.
function utoi ($value) {
	if (gettype ($value) === "boolean")
		return null;
	elseif ((string)$value === (string)((int)$value))
		return (int)$value;
	else
		return null;
}


?>