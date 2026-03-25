<?php
if ($_SERVER["PHP_SELF"] == "/admin/index.php") { // Stop this working outside of the admin page
	include_once $_SERVER['DOCUMENT_ROOT'].'/config/config.php';          // MMDVMDash Config
	include_once $_SERVER['DOCUMENT_ROOT'].'/mmdvmhost/tools.php';        // MMDVMDash Tools
	include_once $_SERVER['DOCUMENT_ROOT'].'/mmdvmhost/functions.php';    // MMDVMDash Functions
	include_once $_SERVER['DOCUMENT_ROOT'].'/config/language.php';        // Translation Code

	// Check if FM is Enabled and SVXLink config exists
	$testMMDVModeFM = getConfigItem("FM", "Enable", $mmdvmconfigs);
	$svxlinkConfigFile = SVXLINKINIPATH."/".SVXLINKINIFILENAME;
	if ( $testMMDVModeFM == 1 && file_exists($svxlinkConfigFile) ) {

	  //Load the svxlink config file
	  $configsvxlink = @parse_ini_file($svxlinkConfigFile, true);

	  if (!empty($_POST) && isset($_POST["svxlinkMgrSubmit"])) {
	    // Handle Posted Data
	    if (preg_match('/[^A-Za-z0-9._:-]/',$_POST['svxlinkReflectorHost'])) { unset ($_POST['svxlinkReflectorHost']); }
	    if (preg_match('/[^0-9]/',$_POST['svxlinkTG'])) { unset ($_POST['svxlinkTG']); }
	    if ($_POST["Link"] == "LINK") {
	      if ($_POST['svxlinkReflectorHost'] == "none") {
		$remoteCommand = "cd /var/log/pi-star && sudo /usr/local/sbin/svxlink_ctrl disconnect";
	      } else {
		$remoteCommand = "cd /var/log/pi-star && sudo /usr/local/sbin/svxlink_ctrl connect ".$_POST['svxlinkReflectorHost']." ".$_POST['svxlinkTG'];
	      }
	    } elseif ($_POST["Link"] == "UNLINK") {
	      $remoteCommand = "cd /var/log/pi-star && sudo /usr/local/sbin/svxlink_ctrl disconnect";
	    } else {
	      echo "<b>SVXLink Manager</b>\n";
	      echo "<table>\n<tr><th>Command Output</th></tr>\n<tr><td>";
	      echo "Something wrong with your input, (Neither Link nor Unlink Sent) - please try again";
	      echo "</td></tr>\n</table>\n<br />\n";
	      unset($_POST);
	      echo '<script type="text/javascript">setTimeout(function() { window.location=window.location;},2000);</script>';
	    }
	    if (empty($_POST['svxlinkReflectorHost'])) {
	      echo "<b>SVXLink Manager</b>\n";
	      echo "<table>\n<tr><th>Command Output</th></tr>\n<tr><td>";
	      echo "Something wrong with your input, (No target specified) - please try again";
	      echo "</td></tr>\n</table>\n<br />\n";
	      unset($_POST);
	      echo '<script type="text/javascript">setTimeout(function() { window.location=window.location;},2000);</script>';
	    }
	    if (isset($remoteCommand)) {
	      echo "<b>SVXLink Manager</b>\n";
	      echo "<table>\n<tr><th>Command Output</th></tr>\n<tr><td>";
	      echo exec($remoteCommand);
	      echo "</td></tr>\n</table>\n<br />\n";
	      echo '<script type="text/javascript">setTimeout(function() { window.location=window.location;},2000);</script>';
	    }
	  } else {
	    // Determine current reflector host
	    if (isset($configsvxlink['ReflectorLogic']['HOST'])) { $testSvxHost = $configsvxlink['ReflectorLogic']['HOST']; } else { $testSvxHost = ""; }
	    if (isset($configsvxlink['ReflectorLogic']['TG'])) { $testSvxTG = $configsvxlink['ReflectorLogic']['TG']; } else { $testSvxTG = "1"; }
	    // Output HTML
	    ?>
	    <b>SVXLink Manager</b>
	    <form action="//<?php echo htmlentities($_SERVER['HTTP_HOST']).htmlentities($_SERVER['PHP_SELF']); ?>" method="post">
	    <table>
	      <tr>
		<th width="150"><a class="tooltip" href="#">Reflector<span><b>SVXReflector Host</b></span></a></th>
		<th width="100"><a class="tooltip" href="#">TG<span><b>Talk Group</b></span></a></th>
		<th width="150"><a class="tooltip" href="#">Link / Un-Link<span><b>Link / Un-Link</b></span></a></th>
		<th width="150"><a class="tooltip" href="#">Action<span><b>Action</b></span></a></th>
	      </tr>
	      <tr>
		<td>
		  <select name="svxlinkReflectorHost">
		  <?php
		  if ($testSvxHost == "") { echo "      <option value=\"none\" selected=\"selected\">None</option>\n"; }
		  else { echo "      <option value=\"none\">None</option>\n"; }
		  // Read SVXLink hosts file
		  if (file_exists('/usr/local/etc/SVXLinkHosts.txt')) {
		    $svxHosts = fopen("/usr/local/etc/SVXLinkHosts.txt", "r");
		    while (!feof($svxHosts)) {
		      $svxHostsLine = fgets($svxHosts);
		      $svxHost = preg_split('/\s+/', trim($svxHostsLine));
		      if ((count($svxHost) >= 2) && (strpos($svxHost[0], '#') === FALSE) && ($svxHost[0] != '')) {
			if ($testSvxHost == $svxHost[1]) { echo "		          <option value=\"$svxHost[1]\" selected=\"selected\">$svxHost[0]</option>\n"; }
			else { echo "		          <option value=\"$svxHost[1]\">$svxHost[0]</option>\n"; }
		      }
		    }
		    fclose($svxHosts);
		  }
		  // Read user-defined SVXLink hosts
		  if (file_exists('/root/SVXLinkHosts.txt')) {
		    $svxHosts2 = fopen("/root/SVXLinkHosts.txt", "r");
		    while (!feof($svxHosts2)) {
		      $svxHostsLine2 = fgets($svxHosts2);
		      $svxHost2 = preg_split('/\s+/', trim($svxHostsLine2));
		      if ((count($svxHost2) >= 2) && (strpos($svxHost2[0], '#') === FALSE) && ($svxHost2[0] != '')) {
			if ($testSvxHost == $svxHost2[1]) { echo "		          <option value=\"$svxHost2[1]\" selected=\"selected\">$svxHost2[0]</option>\n"; }
			else { echo "		          <option value=\"$svxHost2[1]\">$svxHost2[0]</option>\n"; }
		      }
		    }
		    fclose($svxHosts2);
		  }
		  ?>
		  </select>
		</td>
		<td>
		  <input type="text" name="svxlinkTG" value="<?php echo htmlentities($testSvxTG); ?>" size="6" maxlength="10" />
		</td>
		<td>
		  <input type="radio" name="Link" value="LINK" checked="checked" />Link
		  <input type="radio" name="Link" value="UNLINK" />UnLink
		</td>
		<td>
		  <input type="submit" name="svxlinkMgrSubmit" value="Request Change" />
		</td>
	      </tr>
	    </table>
	    </form>
	    <br />
	    <?php
	  }
	}
}
?>
