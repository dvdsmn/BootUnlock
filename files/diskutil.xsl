<?xml version="1.0" encoding="UTF-8"?>
<!--
  Turns the output of "diskutil apfs list -plist" into one line per APFS volume:

      UUID:DEVICE:ENCRYPTED:LOCKED:ROLES:NAME

  ENCRYPTED and LOCKED are "true" or "false", ROLES is a comma-separated list
  (empty for an ordinary volume).

  The volume name is whatever is written on the disk, so it is untrusted
  input.  It comes last, because a name may contain colons, and line breaks
  and tabs are replaced by spaces, so a name can neither add fields nor add
  lines.  The scripts validate the fixed fields again (files/common.sh).
-->
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
  <xsl:output method="text" encoding="UTF-8"/>
  <xsl:template match="/">
    <xsl:apply-templates select="/plist/dict/array[preceding-sibling::key[1] = 'Containers']/dict/array[preceding-sibling::key[1] = 'Volumes']/dict"/>
  </xsl:template>
  <xsl:template match="dict">
    <xsl:value-of select="translate(string[preceding-sibling::key[1] = 'APFSVolumeUUID'], ':&#9;&#10;&#13;', '')"/>
    <xsl:text>:</xsl:text>
    <xsl:value-of select="translate(string[preceding-sibling::key[1] = 'DeviceIdentifier'], ':&#9;&#10;&#13;', '')"/>
    <xsl:text>:</xsl:text>
    <xsl:choose>
      <xsl:when test="true[preceding-sibling::key[1] = 'Encryption']">true</xsl:when>
      <xsl:otherwise>false</xsl:otherwise>
    </xsl:choose>
    <xsl:text>:</xsl:text>
    <xsl:choose>
      <xsl:when test="true[preceding-sibling::key[1] = 'Locked']">true</xsl:when>
      <xsl:otherwise>false</xsl:otherwise>
    </xsl:choose>
    <xsl:text>:</xsl:text>
    <xsl:for-each select="array[preceding-sibling::key[1] = 'Roles']/string">
      <xsl:if test="position() &gt; 1">,</xsl:if>
      <xsl:value-of select="translate(., ':&#9;&#10;&#13;', '')"/>
    </xsl:for-each>
    <xsl:text>:</xsl:text>
    <xsl:value-of select="translate(string[preceding-sibling::key[1] = 'Name'], '&#9;&#10;&#13;', '   ')"/>
    <xsl:text>&#10;</xsl:text>
  </xsl:template>
</xsl:stylesheet>
