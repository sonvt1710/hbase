#
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include Java
java_import java.util.Arrays
java_import java.util.regex.Pattern
java_import org.apache.hadoop.hbase.util.Pair
java_import org.apache.hadoop.hbase.util.RegionSplitter
java_import org.apache.hadoop.hbase.util.Bytes
java_import org.apache.hadoop.hbase.ServerName
java_import org.apache.hadoop.hbase.TableName
java_import org.apache.hadoop.hbase.client.ColumnFamilyDescriptorBuilder
java_import org.apache.hadoop.hbase.client.CoprocessorDescriptorBuilder
java_import org.apache.hadoop.hbase.client.MobCompactPartitionPolicy
java_import org.apache.hadoop.hbase.client.TableDescriptorBuilder
java_import org.apache.hadoop.hbase.HConstants

require 'hbase/balancer_utils'

# Wrapper for org.apache.hadoop.hbase.client.HBaseAdmin

module Hbase
  # rubocop:disable Metrics/ClassLength
  class Admin
    include HBaseConstants

    def initialize(connection)
      @connection = connection
      # Java Admin instance
      @admin = @connection.getAdmin
      @hbck = @connection.getHbck
      @conf = @connection.getConfiguration
    end

    def close
      @admin.close
    end

    #----------------------------------------------------------------------------------------------
    # Returns a list of tables in hbase
    def list(regex = '.*')
      @admin.listTableNames(Pattern.compile(regex)).map(&:getNameAsString)
    end

    #----------------------------------------------------------------------------------------------
    # Requests a table or region or region server flush
    def flush(name, family = nil)
      family_bytes = nil
      family_bytes = family.to_java_bytes unless family.nil?
      if family_bytes.nil?
        @admin.flushRegion(name.to_java_bytes)
      else
        @admin.flushRegion(name.to_java_bytes, family_bytes)
      end
    rescue java.lang.IllegalArgumentException, org.apache.hadoop.hbase.UnknownRegionException
      # Unknown region. Try table.
      begin
        if family_bytes.nil?
          @admin.flush(TableName.valueOf(name))
        else
          @admin.flush(TableName.valueOf(name), family_bytes)
        end
      rescue java.lang.IllegalArgumentException
        # Unknown table. Try region server.
        @admin.flushRegionServer(ServerName.valueOf(name))
      end
    end

    #----------------------------------------------------------------------------------------------
    # Requests a table or region or column family compaction
    def compact(table_or_region_name, family = nil, type = 'NORMAL')
      family_bytes = nil
      family_bytes = family.to_java_bytes unless family.nil?
      compact_type = nil
      if type == 'NORMAL'
        compact_type = org.apache.hadoop.hbase.client.CompactType::NORMAL
      elsif type == 'MOB'
        compact_type = org.apache.hadoop.hbase.client.CompactType::MOB
      else
        raise ArgumentError, 'only NORMAL or MOB accepted for type!'
      end

      begin
        if family_bytes.nil?
          @admin.compactRegion(table_or_region_name.to_java_bytes)
        else
          @admin.compactRegion(table_or_region_name.to_java_bytes, family_bytes)
        end
      rescue java.lang.IllegalArgumentException, org.apache.hadoop.hbase.UnknownRegionException
        if family_bytes.nil?
          @admin.compact(TableName.valueOf(table_or_region_name), compact_type)
        else
          @admin.compact(TableName.valueOf(table_or_region_name), family_bytes, compact_type)
        end
      end
    end

    #----------------------------------------------------------------------------------------------
    # Switch compaction on/off at runtime on a region server
    def compaction_switch(on_or_off, regionserver_names)
      unless /true|false/i.match(on_or_off.to_s)
        raise ArgumentError, 'compaction_switch first argument only accepts "true" or "false"'
      end
      region_servers = regionserver_names.flatten.compact
      servers = java.util.ArrayList.new
      if region_servers.any?
        region_servers.each do |s|
          servers.add(s)
        end
      end
      @admin.compactionSwitch(java.lang.Boolean.valueOf(on_or_off), servers)
    end

    #----------------------------------------------------------------------------------------------
    # Gets compaction state for specified table
    def getCompactionState(table_name)
      @admin.getCompactionState(TableName.valueOf(table_name)).name
    end

    # Requests to compact all regions on the regionserver
    def compact_regionserver(servername, major = false)
      if major
        @admin.majorCompactRegionServer(ServerName.valueOf(servername))
      else
        @admin.compactRegionServer(ServerName.valueOf(servername))
      end
    end

    #----------------------------------------------------------------------------------------------
    # Requests a table or region or column family major compaction
    def major_compact(table_or_region_name, family = nil, type = 'NORMAL')
      family_bytes = nil
      family_bytes = family.to_java_bytes unless family.nil?
      compact_type = nil
      if type == 'NORMAL'
        compact_type = org.apache.hadoop.hbase.client.CompactType::NORMAL
      elsif type == 'MOB'
        compact_type = org.apache.hadoop.hbase.client.CompactType::MOB
      else
        raise ArgumentError, 'only NORMAL or MOB accepted for type!'
      end

      begin
        if family_bytes.nil?
          @admin.majorCompactRegion(table_or_region_name.to_java_bytes)
        else
          @admin.majorCompactRegion(table_or_region_name.to_java_bytes, family_bytes)
        end
      rescue java.lang.IllegalArgumentException, org.apache.hadoop.hbase.UnknownRegionException
        if family_bytes.nil?
          @admin.majorCompact(TableName.valueOf(table_or_region_name), compact_type)
        else
          @admin.majorCompact(TableName.valueOf(table_or_region_name), family_bytes, compact_type)
        end
      end
    end

    #----------------------------------------------------------------------------------------------
    # Requests a regionserver's WAL roll
    def wal_roll(server_name)
      @admin.rollWALWriter(ServerName.valueOf(server_name))
    end
    # TODO: remove older hlog_roll version
    alias hlog_roll wal_roll

    #----------------------------------------------------------------------------------------------
    # Requests a table or region split
    def split(table_or_region_name, split_point = nil)
      split_point_bytes = nil
      split_point_bytes = split_point.to_java_bytes unless split_point.nil?
      begin
        if split_point_bytes.nil?
          org.apache.hadoop.hbase.util.FutureUtils.get(@admin.splitRegionAsync(table_or_region_name.to_java_bytes))
        else
          org.apache.hadoop.hbase.util.FutureUtils.get(@admin.splitRegionAsync(table_or_region_name.to_java_bytes, split_point_bytes))
        end
      rescue java.lang.IllegalArgumentException, org.apache.hadoop.hbase.UnknownRegionException
        if split_point_bytes.nil?
          @admin.split(TableName.valueOf(table_or_region_name))
        else
          @admin.split(TableName.valueOf(table_or_region_name), split_point_bytes)
        end
      end
    end

    #----------------------------------------------------------------------------------------------
    # Requests a region truncate
    def truncate_region(region_name)
      begin
        org.apache.hadoop.hbase.util.FutureUtils.get(@admin.truncateRegionAsync(region_name.to_java_bytes))
      rescue java.lang.IllegalArgumentException, org.apache.hadoop.hbase.UnknownRegionException
        @admin.truncate_region(region_name.to_java_bytes)
      end
    end

    #----------------------------------------------------------------------------------------------
    # Enable/disable one split or merge switch
    # Returns previous switch setting.
    def splitormerge_switch(type, enabled)
      if type == 'SPLIT'
        @admin.splitSwitch(java.lang.Boolean.valueOf(enabled), java.lang.Boolean.valueOf(false))
      elsif type == 'MERGE'
        @admin.mergeSwitch(java.lang.Boolean.valueOf(enabled), java.lang.Boolean.valueOf(false))
      else
        raise ArgumentError, 'only SPLIT or MERGE accepted for type!'
      end
    end

    #----------------------------------------------------------------------------------------------
    # Query the current state of the split or merge switch.
    # Returns the switch's state (true is enabled).
    def splitormerge_enabled(type)
      if type == 'SPLIT'
        @admin.isSplitEnabled
      elsif type == 'MERGE'
        @admin.isMergeEnabled
      else
        raise ArgumentError, 'only SPLIT or MERGE accepted for type!'
      end
    end

    def locate_region(table_name, row_key)
      locator = @connection.getRegionLocator(TableName.valueOf(table_name))
      begin
        return locator.getRegionLocation(Bytes.toBytesBinary(row_key))
      ensure
        locator.close
      end
    end

    #----------------------------------------------------------------------------------------------
    # Requests a cluster balance
    # Returns BalanceResponse with details of the balancer run
    def balancer(*args)
      request = ::Hbase::BalancerUtils.create_balance_request(args)
      @admin.balance(request)
    end

    #----------------------------------------------------------------------------------------------
    # Enable/disable balancer
    # Returns previous balancer switch setting.
    def balance_switch(enableDisable)
      @admin.balancerSwitch(
        java.lang.Boolean.valueOf(enableDisable), java.lang.Boolean.valueOf(false)
      )
    end

    #----------------------------------------------------------------------------------------------
    # Query the current state of the LoadBalancer.
    # Returns the balancer's state (true is enabled).
    def balancer_enabled?
      @admin.isBalancerEnabled
    end

    #----------------------------------------------------------------------------------------------
    # Requests clear block cache for table
    def clear_block_cache(table_name)
      @admin.clearBlockCache(org.apache.hadoop.hbase.TableName.valueOf(table_name)).toString
    end

    #----------------------------------------------------------------------------------------------
    # Requests region normalization for all configured tables in the cluster
    # Returns true if normalize request was successfully submitted
    def normalize(*args)
      builder = org.apache.hadoop.hbase.client.NormalizeTableFilterParams::Builder.new
      args.each do |arg|
        unless arg.is_a?(String) || arg.is_a?(Hash)
          raise(ArgumentError, "#{arg.class} of #{arg.inspect} is not of Hash or String type")
        end

        if arg.key?(TABLE_NAME)
          table_name = arg.delete(TABLE_NAME)
          unless table_name.is_a?(String)
            raise(ArgumentError, "#{TABLE_NAME} must be of type String")
          end

          builder.tableNames(java.util.Collections.singletonList(TableName.valueOf(table_name)))
        elsif arg.key?(TABLE_NAMES)
          table_names = arg.delete(TABLE_NAMES)
          unless table_names.is_a?(Array)
            raise(ArgumentError, "#{TABLE_NAMES} must be of type Array")
          end

          table_name_list = java.util.LinkedList.new
          table_names.each do |tn|
            unless tn.is_a?(String)
              raise(ArgumentError, "#{TABLE_NAMES} value #{tn} must be of type String")
            end

            table_name_list.add(TableName.valueOf(tn))
          end
          builder.tableNames(table_name_list)
        elsif arg.key?(REGEX)
          regex = arg.delete(REGEX)
          raise(ArgumentError, "#{REGEX} must be of type String") unless regex.is_a?(String)

          builder.regex(regex)
        elsif arg.key?(NAMESPACE)
          namespace = arg.delete(NAMESPACE)
          unless namespace.is_a?(String)
            raise(ArgumentError, "#{NAMESPACE} must be of type String")
          end

          builder.namespace(namespace)
        else
          raise(ArgumentError, "Unrecognized argument #{arg}")
        end
      end
      ntfp = builder.build
      @admin.normalize(ntfp)
    end

    #----------------------------------------------------------------------------------------------
    # Enable/disable region normalizer
    # Returns previous normalizer switch setting.
    def normalizer_switch(enableDisable)
      @admin.normalizerSwitch(java.lang.Boolean.valueOf(enableDisable))
    end

    #----------------------------------------------------------------------------------------------
    # Query the current state of region normalizer.
    # Returns the state of region normalizer (true is enabled).
    def normalizer_enabled?
      @admin.isNormalizerEnabled
    end

    #----------------------------------------------------------------------------------------------
    # Query the current state of master in maintenance mode.
    # Returns the state of maintenance mode (true is on).
    def in_maintenance_mode?
      @admin.isMasterInMaintenanceMode
    end

    #----------------------------------------------------------------------------------------------
    # Request HBCK chore to run
    def hbck_chore_run
      @hbck.runHbckChore
    end

    #----------------------------------------------------------------------------------------------
    # Request a scan of the catalog table (for garbage collection)
    # Returns an int signifying the number of entries cleaned
    def catalogjanitor_run
      @admin.runCatalogJanitor
    end

    #----------------------------------------------------------------------------------------------
    # Enable/disable the catalog janitor
    # Returns previous catalog janitor switch setting.
    def catalogjanitor_switch(enableDisable)
      @admin.catalogJanitorSwitch(java.lang.Boolean.valueOf(enableDisable))
    end

    #----------------------------------------------------------------------------------------------
    # Query on the catalog janitor state (enabled/disabled?)
    # Returns catalog janitor state (true signifies enabled).
    def catalogjanitor_enabled
      @admin.isCatalogJanitorEnabled
    end

    #----------------------------------------------------------------------------------------------
    # Request cleaner chore to run (for garbage collection of HFiles and WAL files)
    def cleaner_chore_run
      @admin.runCleanerChore
    end

    #----------------------------------------------------------------------------------------------
    # Enable/disable the cleaner chore
    # Returns previous cleaner switch setting.
    def cleaner_chore_switch(enableDisable)
      @admin.cleanerChoreSwitch(java.lang.Boolean.valueOf(enableDisable))
    end

    #----------------------------------------------------------------------------------------------
    # Query on the cleaner chore state (enabled/disabled?)
    # Returns cleaner state (true signifies enabled).
    def cleaner_chore_enabled
      @admin.isCleanerChoreEnabled
    end

    #----------------------------------------------------------------------------------------------
    # Enables a table
    def enable(table_name)
      tableExists(table_name)
      return if enabled?(table_name)
      @admin.enableTable(TableName.valueOf(table_name))
    end

    #----------------------------------------------------------------------------------------------
    # Enables all tables matching the given regex
    def enable_all(regex)
      pattern = Pattern.compile(regex.to_s)
      failed = java.util.ArrayList.new
      @admin.listTableNames(pattern).each do |table_name|
        begin
          @admin.enableTable(table_name)
        rescue java.io.IOException => e
          puts "table:#{table_name}, error:#{e.toString}"
          failed.add(table_name)
        end
      end
      failed
    end

    #----------------------------------------------------------------------------------------------
    # Disables a table
    def disable(table_name)
      tableExists(table_name)
      return if disabled?(table_name)
      @admin.disableTable(TableName.valueOf(table_name))
    end

    #----------------------------------------------------------------------------------------------
    # Disables all tables matching the given regex
    def disable_all(regex)
      pattern = Pattern.compile(regex.to_s)
      failed = java.util.ArrayList.new
      @admin.listTableNames(pattern).each do |table_name|
        begin
          @admin.disableTable(table_name)
        rescue java.io.IOException => e
          puts "table:#{table_name}, error:#{e.toString}"
          failed.add(table_name)
        end
      end
      failed
    end

    #---------------------------------------------------------------------------------------------
    # Throw exception if table doesn't exist
    def tableExists(table_name)
      raise ArgumentError, "Table #{table_name} does not exist." unless exists?(table_name)
    end

    #----------------------------------------------------------------------------------------------
    # Is table disabled?
    def disabled?(table_name)
      @admin.isTableDisabled(TableName.valueOf(table_name))
    end

    #----------------------------------------------------------------------------------------------
    # Drops a table
    def drop(table_name)
      tableExists(table_name)
      raise ArgumentError, "Table #{table_name} is enabled. Disable it first." if enabled?(
        table_name
      )

      @admin.deleteTable(org.apache.hadoop.hbase.TableName.valueOf(table_name))
    end

    #----------------------------------------------------------------------------------------------
    # Drops a table
    def drop_all(regex)
      pattern = Pattern.compile(regex.to_s)
      failed = java.util.ArrayList.new
      @admin.listTableNames(pattern).each do |table_name|
        begin
          @admin.deleteTable(table_name)
        rescue java.io.IOException => e
          puts puts "table:#{table_name}, error:#{e.toString}"
          failed.add(table_name)
        end
      end
      failed
    end

    #----------------------------------------------------------------------------------------------
    # Returns ZooKeeper status dump
    def zk_dump
      @zk_wrapper = org.apache.hadoop.hbase.zookeeper.ZKWatcher.new(
        @admin.getConfiguration,
        'admin',
        nil
      )
      org.apache.hadoop.hbase.zookeeper.ZKDump.dump(@zk_wrapper)
    end

    #----------------------------------------------------------------------------------------------
    # Creates a table
    def create(table_name, *args)
      # Fail if table name is not a string
      raise(ArgumentError, 'Table name must be of type String') unless table_name.is_a?(String)

      # Flatten params array
      args = args.flatten.compact
      has_columns = false

      # Start defining the table
      tdb = TableDescriptorBuilder.newBuilder(TableName.valueOf(table_name))
      splits = nil
      # Args are either columns or splits, add them to the table definition
      # TODO: add table options support
      args.each do |arg|
        unless arg.is_a?(String) || arg.is_a?(Hash)
          raise(ArgumentError, "#{arg.class} of #{arg.inspect} is not of Hash or String type")
        end

        # First, handle all the cases where arg is a column family.
        if arg.is_a?(String) || arg.key?(NAME)
          # If the arg is a string, default action is to add a column to the table.
          # If arg has a name, it must also be a column descriptor.
          descriptor = cfd(arg, tdb)
          # Warn if duplicate columns are added
          if tdb.build.hasColumnFamily(descriptor.getName)
            puts "Family '" + descriptor.getNameAsString + "' already exists, the old one will be replaced"
            tdb.modifyColumnFamily(descriptor)
          else
            tdb.setColumnFamily(descriptor)
          end
          has_columns = true
          next
        end
        if arg.key?(REGION_REPLICATION)
          region_replication = JInteger.valueOf(arg.delete(REGION_REPLICATION))
          tdb.setRegionReplication(region_replication)
        end

        # Get rid of the "METHOD", which is deprecated for create.
        # We'll do whatever it used to do below if it's table_att.
        if (method = arg.delete(METHOD))
          raise(ArgumentError, 'table_att is currently the only supported method') unless method == 'table_att'
        end

        # The hash is not a column family. Figure out what's in it.
        # First, handle splits.
        if arg.key?(SPLITS_FILE)
          splits_file = arg.delete(SPLITS_FILE)
          unless File.exist?(splits_file)
            raise(ArgumentError, "Splits file #{splits_file} doesn't exist")
          end
          arg[SPLITS] = []
          File.foreach(splits_file) do |line|
            arg[SPLITS].push(line.chomp)
          end
          tdb.setValue(SPLITS_FILE, splits_file)
        end

        if arg.key?(SPLITS)
          splits = Java::byte[][arg[SPLITS].size].new
          idx = 0
          arg.delete(SPLITS).each do |split|
            splits[idx] = org.apache.hadoop.hbase.util.Bytes.toBytesBinary(split)
            idx += 1
          end
        elsif arg.key?(NUMREGIONS) || arg.key?(SPLITALGO)
          # deprecated region pre-split API; if one of the above is specified, will be ignored.
          raise(ArgumentError, 'Number of regions must be specified') unless arg.key?(NUMREGIONS)
          raise(ArgumentError, 'Split algorithm must be specified') unless arg.key?(SPLITALGO)
          raise(ArgumentError, 'Number of regions must be greater than 1') unless arg[NUMREGIONS] > 1
          num_regions = arg.delete(NUMREGIONS)
          split_algo = RegionSplitter.newSplitAlgoInstance(@conf, arg.delete(SPLITALGO))
          splits = split_algo.split(JInteger.valueOf(num_regions))
        end

        # Done with splits; apply formerly-table_att parameters.
        update_tdb_from_arg(tdb, arg)

        arg.each_key do |ignored_key|
          puts(format('An argument ignored (unknown or overridden): %s', ignored_key))
        end
      end

      # Fail if no column families defined
      raise(ArgumentError, 'Table must have at least one column family') unless has_columns

      if splits.nil?
        # Perform the create table call
        @admin.createTable(tdb.build)
      else
        # Perform the create table call
        @admin.createTable(tdb.build, splits)
      end
    end

    #----------------------------------------------------------------------------------------------
    #----------------------------------------------------------------------------------------------
    # Assign a region
    def assign(region_name)
      @admin.assign(region_name.to_java_bytes)
    end

    #----------------------------------------------------------------------------------------------
    # Unassign a region
    # the force parameter is deprecated, if it is specified, will be ignored.
    def unassign(region_name, force = nil)
      @admin.unassign(region_name.to_java_bytes)
    end

    #----------------------------------------------------------------------------------------------
    # Move a region
    def move(encoded_region_name, server = nil)
      @admin.move(encoded_region_name.to_java_bytes, server ? server.to_java_bytes : nil)
    end

    #----------------------------------------------------------------------------------------------
    # Merge multiple regions
    def merge_region(regions, force)
      unless regions.is_a?(Array)
        raise(ArgumentError, "Type of #{regions.inspect} is #{regions.class}, but expected Array")
      end
      region_array = Java::byte[][regions.length].new
      i = 0
      while i < regions.length
        unless regions[i].is_a?(String)
          raise(
              ArgumentError,
              "Type of #{regions[i].inspect} is #{regions[i].class}, but expected String"
          )
        end
        region_array[i] = regions[i].to_java_bytes
        i += 1
      end
      org.apache.hadoop.hbase.util.FutureUtils.get(
          @admin.mergeRegionsAsync(
              region_array,
              java.lang.Boolean.valueOf(force)
          )
      )
    end

    #----------------------------------------------------------------------------------------------
    # Returns table's structure description
    def describe(table_name)
      tableExists(table_name)
      @admin.getDescriptor(TableName.valueOf(table_name)).to_s
    end

    def get_column_families(table_name)
      tableExists(table_name)
      @admin.getDescriptor(TableName.valueOf(table_name)).getColumnFamilies
    end

    def get_table_attributes(table_name)
      tableExists(table_name)
      td = @admin.getDescriptor TableName.valueOf(table_name)
      # toStringTableAttributes is a public method, but it is defined on the private class
      # ModifiableTableDescriptor, so we need reflection to access it in JDK 11+.
      # TODO Maybe move this to a utility class in the future?
      method = td.java_class.declared_method :toStringTableAttributes
      method.accessible = true
      method.invoke td
    end

    #----------------------------------------------------------------------------------------------
    # Enable/disable snapshot auto-cleanup based on TTL expiration
    # Returns previous snapshot auto-cleanup switch setting.
    def snapshot_cleanup_switch(enable_disable)
      @admin.snapshotCleanupSwitch(
        java.lang.Boolean.valueOf(enable_disable), java.lang.Boolean.valueOf(false)
      )
    end

    #----------------------------------------------------------------------------------------------
    # Query the current state of the snapshot auto-cleanup based on TTL
    # Returns the snapshot auto-cleanup state (true if enabled)
    def snapshot_cleanup_enabled?
      @admin.isSnapshotCleanupEnabled
    end

    #----------------------------------------------------------------------------------------------
    # Truncates table (deletes all records by recreating the table)
    def truncate(table_name_str)
      puts "Truncating '#{table_name_str}' table (it may take a while):"
      table_name = TableName.valueOf(table_name_str)

      if enabled?(table_name_str)
        puts 'Disabling table...'
        disable(table_name_str)
      end

      puts 'Truncating table...'
      @admin.truncateTable(table_name, false)
    end

    #----------------------------------------------------------------------------------------------
    # Truncates table while maintaining region boundaries
    # (deletes all records by recreating the table)
    def truncate_preserve(table_name_str)
      puts "Truncating '#{table_name_str}' table (it may take a while):"
      table_name = TableName.valueOf(table_name_str)

      if enabled?(table_name_str)
        puts 'Disabling table...'
        disable(table_name_str)
      end

      puts 'Truncating table...'
      @admin.truncateTable(table_name, true)
    end

    #----------------------------------------------------------------------------------------------
    # Check the status of alter command (number of regions reopened)
    def alter_status(table_name)
      # Table name should be a string
      raise(ArgumentError, 'Table name must be of type String') unless table_name.is_a?(String)

      # Table should exist
      raise(ArgumentError, "Can't find a table: #{table_name}") unless exists?(table_name)

      begin
        cluster_metrics = @admin.getClusterMetrics
        table_region_status = cluster_metrics
                              .getTableRegionStatesCount
                              .get(org.apache.hadoop.hbase.TableName.valueOf(table_name))
        if table_region_status.getTotalRegions != 0
          updated_regions = table_region_status.getTotalRegions -
                            table_region_status.getRegionsInTransition -
                            table_region_status.getClosedRegions
          puts "#{updated_regions}/#{table_region_status.getTotalRegions} regions updated."
        else
          puts 'All regions updated.'
        end
        sleep 1
      end while !table_region_status.nil? && table_region_status.getRegionsInTransition != 0
      puts 'Done.'
    end

    #----------------------------------------------------------------------------------------------
    # Use our internal logic to convert from "spec string" format to a coprocessor descriptor
    #
    # Provided for backwards shell compatibility
    #
    # @param [String] spec_str
    # @return [ColumnDescriptor]
    def coprocessor_descriptor_from_spec_str(spec_str)
      method = TableDescriptorBuilder.java_class.declared_method_smart :toCoprocessorDescriptor
      method.accessible = true
      result = method.invoke(nil, spec_str).to_java
      # unpack java's Optional to be more rubonic
      return result.isPresent ? result.get : nil
    end

    #----------------------------------------------------------------------------------------------
    # Use CoprocessorDescriptorBuilder to convert a Hash to CoprocessorDescriptor
    #
    # @param [Hash] spec column descriptor specification
    # @return [ColumnDescriptor]
    def coprocessor_descriptor_from_hash(spec)
      classname = spec[CLASSNAME]
      raise ArgumentError.new "CLASSNAME must be provided in spec" if classname.nil?
      jar_path = spec[JAR_PATH]
      priority = spec[PRIORITY]
      properties = spec[PROPERTIES]

      builder = CoprocessorDescriptorBuilder.newBuilder classname
      builder.setJarPath jar_path unless jar_path.nil?
      builder.setPriority priority unless priority.nil?
      properties&.each { |k, v| builder.setProperty(k, v.to_s) }

      builder.build
    end

    #----------------------------------------------------------------------------------------------
    # Change table structure or table options
    def alter(table_name_str, wait = true, *args)
      # Table name should be a string
      raise(ArgumentError, 'Table name must be of type String') unless
          table_name_str.is_a?(String)

      # Table should exist
      raise(ArgumentError, "Can't find a table: #{table_name_str}") unless exists?(table_name_str)

      # There should be at least one argument
      raise(ArgumentError, 'There should be at least one argument but the table name') if args.empty?

      table_name = TableName.valueOf(table_name_str)

      # Get table descriptor
      tdb = TableDescriptorBuilder.newBuilder(@admin.getDescriptor(table_name))
      hasTableUpdate = false
      reopen_regions = true

      # Process all args
      args.each do |arg|
        # Normalize args to support column name only alter specs
        arg = { NAME => arg } if arg.is_a?(String)

        # Normalize args to support shortcut delete syntax
        arg = { METHOD => 'delete', NAME => arg['delete'] } if arg['delete']

        if arg.key?(REOPEN_REGIONS)
          if !['true', 'false'].include?(arg[REOPEN_REGIONS].downcase)
            raise(ArgumentError, "Invalid 'REOPEN_REGIONS' for non-boolean value.")
          end
          reopen_regions = JBoolean.valueOf(arg[REOPEN_REGIONS])
          arg.delete(REOPEN_REGIONS)
        end

        # There are 3 possible options.
        # 1) Column family spec. Distinguished by having a NAME and no METHOD.
        method = arg.delete(METHOD)
        if method.nil? && arg.key?(NAME)
          descriptor = cfd(arg, tdb)
          column_name = descriptor.getNameAsString

          # If column already exist, then try to alter it. Create otherwise.
          if tdb.build.hasColumnFamily(column_name.to_java_bytes)
            tdb.modifyColumnFamily(descriptor)
          else
            tdb.setColumnFamily(descriptor)
          end
          hasTableUpdate = true
          next
        end

        # 2) Method other than table_att, with some args.
        name = arg.delete(NAME)
        if !method.nil? && method != 'table_att'
          # Delete column family
          if method == 'delete'
            raise(ArgumentError, 'NAME parameter missing for delete method') unless name
            tdb.removeColumnFamily(name.to_java_bytes)
            hasTableUpdate = true
          # Unset table attributes
          elsif method == 'table_att_unset'
            raise(ArgumentError, 'NAME parameter missing for table_att_unset method') unless name
            if name.is_a?(Array)
              name.each do |key|
                if tdb.build.getValue(key).nil?
                  raise ArgumentError, "Could not find attribute: #{key}"
                end
                tdb.removeValue(key)
              end
            else
              if tdb.build.getValue(name).nil?
                raise ArgumentError, "Could not find attribute: #{name}"
              end
              tdb.removeValue(name)
            end
            hasTableUpdate = true
          elsif method == 'table_remove_coprocessor'
            classname = arg.delete(CLASSNAME)
            raise(ArgumentError, 'CLASSNAME parameter missing for table_remove_coprocessor method') unless classname
            if classname.is_a?(Array)
              classname.each do |key|
                tdb.removeCoprocessor(key)
              end
            else
              tdb.removeCoprocessor(classname)
            end
            hasTableUpdate = true
          # Unset table configuration
          elsif method == 'table_conf_unset'
            raise(ArgumentError, 'NAME parameter missing for table_conf_unset method') unless name
            if name.is_a?(Array)
              name.each do |key|
                if tdb.build.getValue(key).nil?
                  raise ArgumentError, "Could not find configuration: #{key}"
                end
                tdb.removeValue(key)
              end
            else
              if tdb.build.getValue(name).nil?
                raise ArgumentError, "Could not find configuration: #{name}"
              end
              tdb.removeValue(name)
            end
            hasTableUpdate = true
          # Unknown method
          else
            raise ArgumentError, "Unknown method: #{method}"
          end

          arg.each_key do |unknown_key|
            puts(format('Unknown argument ignored: %s', unknown_key))
          end

          next
        end

        # 3) Some args for the table, optionally with METHOD => table_att (deprecated)
        update_tdb_from_arg(tdb, arg)

        # set a coprocessor attribute
        valid_coproc_keys = []
        next unless arg.is_a?(Hash)
        arg.each do |key, value|
          k = String.new(key) # prepare to strip
          k.strip!

          # Uses insensitive matching so we can accept lowercase 'coprocessor' for compatibility
          next unless k =~ /#{COPROCESSOR}/i
          if value.is_a? String
            # Specifying a coprocessor by this "spec string" is here for backwards compatibility
            v = String.new value
            v.strip!
            cp = coprocessor_descriptor_from_spec_str v
          elsif value.is_a? Hash
            cp = coprocessor_descriptor_from_hash value
          else
            raise ArgumentError.new 'coprocessor must be provided as a String or Hash'
          end
          tdb.setCoprocessor cp
          valid_coproc_keys << key
        end

        valid_coproc_keys.each do |key|
          arg.delete(key)
        end

        hasTableUpdate = true

        arg.each_key do |unknown_key|
          puts(format('Unknown argument ignored: %s', unknown_key))
        end

        next
      end

      # Bulk apply all table modifications.
      if hasTableUpdate
        future = @admin.modifyTableAsync(tdb.build, reopen_regions)
        if reopen_regions == false
          puts("WARNING: You are using REOPEN_REGIONS => 'false' to modify a table, which will
          result in inconsistencies in the configuration of online regions and other risks. If you
          encounter any issues, use the original 'alter' command to make the modification again!")
          future.get
        elsif wait == true
          puts 'Updating all regions with the new schema...'
          future.get
        end
      end
    end

    def status(format, type)
      cluster_metrics = @admin.getClusterMetrics
      if format == 'detailed'
        puts(format('version %s', cluster_metrics.getHBaseVersion))
        # Put regions in transition first because usually empty
        puts(format('%d regionsInTransition', cluster_metrics.getRegionStatesInTransition.size))
        for v in cluster_metrics.getRegionStatesInTransition
          puts(format('    %s', v))
        end
        master = cluster_metrics.getMasterName
        unless master.nil?
          puts(format('active master:  %s:%d %d', master.getHostname, master.getPort, master.getStartcode))
          for task in cluster_metrics.getMasterTasks
            puts(format('    %s', task.toString))
          end
        end
        puts(format('%d backup masters', cluster_metrics.getBackupMasterNames.size))
        for server in cluster_metrics.getBackupMasterNames
          puts(format('    %s:%d %d', server.getHostname, server.getPort, server.getStartcode))
        end
        master_coprocs = @admin.getMasterCoprocessorNames.toString
        unless master_coprocs.nil?
          puts(format('master coprocessors: %s', master_coprocs))
        end
        puts(format('%d live servers', cluster_metrics.getLiveServerMetrics.size))
        for server in cluster_metrics.getLiveServerMetrics.keySet
          puts(format('    %s:%d %d', server.getHostname, server.getPort, server.getStartcode))
          puts(format('        %s', cluster_metrics.getLiveServerMetrics.get(server).toString))
          for name, region in cluster_metrics.getLiveServerMetrics.get(server).getRegionMetrics
            puts(format('        %s', region.getNameAsString.dump))
            puts(format('            %s', region.toString))
          end
          for task in cluster_metrics.getLiveServerMetrics.get(server).getTasks
            puts(format('        %s', task.toString))
          end
        end
        puts(format('%d dead servers', cluster_metrics.getDeadServerNames.size))
        for server in cluster_metrics.getDeadServerNames
          puts(format('    %s', server))
        end
      elsif format == 'replication'
        puts(format('version %<version>s', version: cluster_metrics.getHBaseVersion))
        puts(format('%<servers>d live servers',
                    servers: cluster_metrics.getLiveServerMetrics.size))
        cluster_metrics.getLiveServerMetrics.keySet.each do |server_name|
          sl = cluster_metrics.getLiveServerMetrics.get(server_name)
          r_sink_string   = '        SINK:'
          r_source_string = '        SOURCE:'
          r_load_sink = sl.getReplicationLoadSink
          next if r_load_sink.nil?

          if r_load_sink.getTimestampsOfLastAppliedOp() == r_load_sink.getTimestampStarted()
          # If we have applied no operations since we've started replication,
          # assume that we're not acting as a sink and don't print the normal information
            r_sink_string << "\n            TimeStampStarted=" + r_load_sink.getTimestampStarted().to_s
            r_sink_string << ",\n            Waiting for OPs... "
          else
            r_sink_string << "\n            TimeStampStarted=" + r_load_sink.getTimestampStarted().to_s
            r_sink_string << ",\n            AgeOfLastAppliedOp=" + r_load_sink.getAgeOfLastAppliedOp().to_s
            r_sink_string << ",\n            TimeStampsOfLastAppliedOp=" +
               r_load_sink.getTimestampsOfLastAppliedOp().to_s
          end

          r_load_source_map = sl.getReplicationLoadSourceMap
          build_source_string(r_load_source_map, r_source_string)

          puts(format('    %<host>s:', host: server_name.getHostname))
          if type.casecmp('SOURCE').zero?
            puts(format('%<source>s', source: r_source_string))
          elsif type.casecmp('SINK').zero?
            puts(format('%<sink>s', sink: r_sink_string))
          else
            puts(format('%<source>s', source: r_source_string))
            puts(format('%<sink>s', sink: r_sink_string))
          end
        end
      elsif format == 'tasks'
        master = cluster_metrics.getMasterName
        unless master.nil?
          puts(format('active master:  %s:%d %d', master.getHostname, master.getPort, master.getStartcode))
          printed = false
          for task in cluster_metrics.getMasterTasks
            next unless task.getState.name == 'RUNNING'
            puts(format('    %s', task.toString))
            printed = true
          end
          if !printed
            puts('    no active tasks')
          end
        end
        puts(format('%d live servers', cluster_metrics.getServersSize))
        for server in cluster_metrics.getServers
          puts(format('    %s:%d %d', server.getHostname, server.getPort, server.getStartcode))
          printed = false
          for task in cluster_metrics.getLiveServerMetrics.get(server).getTasks
            next unless task.getState.name == 'RUNNING'
            puts(format('        %s', task.toString))
            printed = true
          end
          if !printed
            puts('        no active tasks')
          end
        end
      elsif format == 'simple'
        load = 0
        regions = 0
        master = cluster_metrics.getMasterName
        puts(format('active master:  %s:%d %d', master.getHostname, master.getPort,
                    master.getStartcode))
        puts(format('%d backup masters', cluster_metrics.getBackupMasterNames.size))
        for server in cluster_metrics.getBackupMasterNames
          puts(format('    %s:%d %d', server.getHostname, server.getPort, server.getStartcode))
        end
        puts(format('%d live servers', cluster_metrics.getLiveServerMetrics.size))
        for server in cluster_metrics.getLiveServerMetrics.keySet
          puts(format('    %s:%d %d', server.getHostname, server.getPort, server.getStartcode))
          puts(format('        %s', cluster_metrics.getLiveServerMetrics.get(server).toString))
          load += cluster_metrics.getLiveServerMetrics.get(server).getRequestCountPerSecond
          regions += cluster_metrics.getLiveServerMetrics.get(server).getRegionMetrics.size
        end
        puts(format('%d dead servers', cluster_metrics.getDeadServerNames.size))
        for server in cluster_metrics.getDeadServerNames
          puts(format('    %s', server))
        end
        puts(format('Aggregate load: %d, regions: %d', load, regions))
      else
        puts "1 active master, #{cluster_metrics.getBackupMasterNames.size} backup masters,
              #{cluster_metrics.getLiveServerMetrics.size} servers,
              #{cluster_metrics.getDecommissionedServerNames.size} decommissioned,
              #{cluster_metrics.getDeadServerNames.size} dead,
              #{format('%.4f', cluster_metrics.getAverageLoad)} average load"
      end
    end

    def build_source_string(r_load_source_map, r_source_string)
      r_load_source_map.each do |peer, sources|
        r_source_string << "\n            PeerID=" + peer
        sources.each do |source_load|
          build_queue_title(source_load, r_source_string)
          build_running_source_stats(source_load, r_source_string)
          r_source_string << "\n"
        end
      end
    end

    def build_queue_title(source_load, r_source_string)
      r_source_string << if source_load.isRecovered
                           ",\n            Queue(Recovered)="
                         else
                           ",\n            Queue(Normal)="
                         end
      r_source_string << source_load.getQueueId
    end

    def build_running_source_stats(source_load, r_source_string)
      if source_load.isRunning
        build_shipped_stats(source_load, r_source_string)
        build_load_general_stats(source_load, r_source_string)
        r_source_string << ",\n            ReplicationLag=" +
                           source_load.getReplicationLag.to_s
      else
        r_source_string << ",\n            IsRunning=false, "
        r_source_string << 'No Reader/Shipper threads runnning yet.'
      end
    end

    def build_shipped_stats(source_load, r_source_string)
      r_source_string << if source_load.getTimestampOfLastShippedOp.zero?
                           ",\n            TimeStampOfLastShippedOp=0, " \
                           'No Ops shipped since last restart'
                         else
                           ",\n            AgeOfLastShippedOp=" +
                           source_load.getAgeOfLastShippedOp.to_s +
                           ",\n            TimeStampOfLastShippedOp=" +
                           source_load.getTimestampOfLastShippedOp.to_s
                         end
    end

    def build_load_general_stats(source_load, r_source_string)
      r_source_string << ",\n            SizeOfLogQueue=" +
                         source_load.getSizeOfLogQueue.to_s
      r_source_string << ",\n            EditsReadFromLogQueue=" +
                         source_load.getEditsRead.to_s
      r_source_string << ",\n            OpsShippedToTarget=" +
                         source_load.getOPsShipped.to_s
      build_edits_for_source(source_load, r_source_string)
    end

    def build_edits_for_source(source_load, r_source_string)
      if source_load.hasEditsSinceRestart
        r_source_string << ",\n            TimeStampOfNextToReplicate=" +
                           source_load.getTimeStampOfNextToReplicate.to_s
      else
        r_source_string << ",\n            HasEditsSinceRestart=false, "
        r_source_string << 'No edits for this source since it started'
      end
    end

    #----------------------------------------------------------------------------------------------
    #
    # Helper methods
    #

    # Does table exist?
    def exists?(table_name)
      @admin.tableExists(TableName.valueOf(table_name))
    end

    #----------------------------------------------------------------------------------------------
    # Is table enabled
    def enabled?(table_name)
      @admin.isTableEnabled(TableName.valueOf(table_name))
    end

    #----------------------------------------------------------------------------------------------
    # Return a new ColumnFamilyDescriptor made of passed args
    def cfd(arg, tdb)
      # String arg, single parameter constructor
      return ColumnFamilyDescriptorBuilder.of(arg) if arg.is_a?(String)

      raise(ArgumentError, "Column family #{arg} must have a name") unless name = arg.delete(NAME)

      descriptor = tdb.build.getColumnFamily(name.to_java_bytes)
      unless descriptor.nil?
        cfdb = ColumnFamilyDescriptorBuilder.newBuilder(descriptor)
      end
      # create it if it's a new family
      cfdb ||= ColumnFamilyDescriptorBuilder.newBuilder(name.to_java_bytes)

      cfdb.setBlockCacheEnabled(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::BLOCKCACHE))) if arg.include?(ColumnFamilyDescriptorBuilder::BLOCKCACHE)
      cfdb.setScope(JInteger.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::REPLICATION_SCOPE))) if arg.include?(ColumnFamilyDescriptorBuilder::REPLICATION_SCOPE)
      cfdb.setCacheDataOnWrite(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::CACHE_DATA_ON_WRITE))) if arg.include?(ColumnFamilyDescriptorBuilder::CACHE_DATA_ON_WRITE)
      cfdb.setCacheIndexesOnWrite(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::CACHE_INDEX_ON_WRITE))) if arg.include?(ColumnFamilyDescriptorBuilder::CACHE_INDEX_ON_WRITE)
      cfdb.setCacheBloomsOnWrite(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::CACHE_BLOOMS_ON_WRITE))) if arg.include?(ColumnFamilyDescriptorBuilder::CACHE_BLOOMS_ON_WRITE)
      cfdb.setEvictBlocksOnClose(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::EVICT_BLOCKS_ON_CLOSE))) if arg.include?(ColumnFamilyDescriptorBuilder::EVICT_BLOCKS_ON_CLOSE)
      cfdb.setInMemory(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::IN_MEMORY))) if arg.include?(ColumnFamilyDescriptorBuilder::IN_MEMORY)
      if arg.include?(ColumnFamilyDescriptorBuilder::IN_MEMORY_COMPACTION)
        cfdb.setInMemoryCompaction(
          org.apache.hadoop.hbase.MemoryCompactionPolicy.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::IN_MEMORY_COMPACTION))
        )
      end
      cfdb.setTimeToLive(arg.delete(ColumnFamilyDescriptorBuilder::TTL)) if arg.include?(ColumnFamilyDescriptorBuilder::TTL)
      cfdb.setDataBlockEncoding(org.apache.hadoop.hbase.io.encoding.DataBlockEncoding.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::DATA_BLOCK_ENCODING))) if arg.include?(ColumnFamilyDescriptorBuilder::DATA_BLOCK_ENCODING)
      cfdb.setBlocksize(arg.delete(ColumnFamilyDescriptorBuilder::BLOCKSIZE)) if arg.include?(ColumnFamilyDescriptorBuilder::BLOCKSIZE)
      cfdb.setMaxVersions(JInteger.valueOf(arg.delete(HConstants::VERSIONS))) if arg.include?(HConstants::VERSIONS)
      cfdb.setMinVersions(JInteger.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::MIN_VERSIONS))) if arg.include?(ColumnFamilyDescriptorBuilder::MIN_VERSIONS)
      cfdb.setKeepDeletedCells(org.apache.hadoop.hbase.KeepDeletedCells.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::KEEP_DELETED_CELLS).to_s.upcase)) if arg.include?(ColumnFamilyDescriptorBuilder::KEEP_DELETED_CELLS)
      cfdb.setCompressTags(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::COMPRESS_TAGS))) if arg.include?(ColumnFamilyDescriptorBuilder::COMPRESS_TAGS)
      cfdb.setPrefetchBlocksOnOpen(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::PREFETCH_BLOCKS_ON_OPEN))) if arg.include?(ColumnFamilyDescriptorBuilder::PREFETCH_BLOCKS_ON_OPEN)
      cfdb.setMobEnabled(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::IS_MOB))) if arg.include?(ColumnFamilyDescriptorBuilder::IS_MOB)
      cfdb.setMobThreshold(JLong.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::MOB_THRESHOLD))) if arg.include?(ColumnFamilyDescriptorBuilder::MOB_THRESHOLD)
      cfdb.setNewVersionBehavior(JBoolean.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::NEW_VERSION_BEHAVIOR))) if arg.include?(ColumnFamilyDescriptorBuilder::NEW_VERSION_BEHAVIOR)
      if arg.include?(ColumnFamilyDescriptorBuilder::BLOOMFILTER)
        bloomtype = arg.delete(ColumnFamilyDescriptorBuilder::BLOOMFILTER).upcase.to_sym
        if org.apache.hadoop.hbase.regionserver.BloomType.constants.include?(bloomtype)
          cfdb.setBloomFilterType(org.apache.hadoop.hbase.regionserver.BloomType.valueOf(bloomtype))
        else
          raise(ArgumentError, "BloomFilter type #{bloomtype} is not supported. Use one of " + org.apache.hadoop.hbase.regionserver.BloomType.constants.join(' '))
        end
      end
      if arg.include?(ColumnFamilyDescriptorBuilder::COMPRESSION)
        compression = arg.delete(ColumnFamilyDescriptorBuilder::COMPRESSION).upcase.to_sym
        if org.apache.hadoop.hbase.io.compress.Compression::Algorithm.constants.include?(compression)
          cfdb.setCompressionType(org.apache.hadoop.hbase.io.compress.Compression::Algorithm.valueOf(compression))
        else
          raise(ArgumentError, "Compression #{compression} is not supported. Use one of " + org.apache.hadoop.hbase.io.compress.Compression::Algorithm.constants.join(' '))
        end
      end
      if arg.include?(ColumnFamilyDescriptorBuilder::ENCRYPTION)
        algorithm = arg.delete(ColumnFamilyDescriptorBuilder::ENCRYPTION).upcase
        cfdb.setEncryptionType(algorithm)
        if arg.include?(ColumnFamilyDescriptorBuilder::ENCRYPTION_KEY)
          key = org.apache.hadoop.hbase.io.crypto.Encryption.generateSecretKey(
            @conf, algorithm, arg.delete(ColumnFamilyDescriptorBuilder::ENCRYPTION_KEY)
          )
          cfdb.setEncryptionKey(org.apache.hadoop.hbase.security.EncryptionUtil.wrapKey(@conf, key,
                                                                                          algorithm))
        end
      end
      if arg.include?(ColumnFamilyDescriptorBuilder::COMPRESSION_COMPACT)
        compression = arg.delete(ColumnFamilyDescriptorBuilder::COMPRESSION_COMPACT).upcase.to_sym
        if org.apache.hadoop.hbase.io.compress.Compression::Algorithm.constants.include?(compression)
          cfdb.setCompactionCompressionType(org.apache.hadoop.hbase.io.compress.Compression::Algorithm.valueOf(compression))
        else
          raise(ArgumentError, "Compression #{compression} is not supported. Use one of " + org.apache.hadoop.hbase.io.compress.Compression::Algorithm.constants.join(' '))
        end
      end
      if arg.include?(ColumnFamilyDescriptorBuilder::COMPRESSION_COMPACT_MAJOR)
        compression = arg.delete(ColumnFamilyDescriptorBuilder::COMPRESSION_COMPACT_MAJOR).upcase.to_sym
        if org.apache.hadoop.hbase.io.compress.Compression::Algorithm.constants.include?(compression)
          cfdb.setMajorCompactionCompressionType(org.apache.hadoop.hbase.io.compress.Compression::Algorithm.valueOf(compression))
        else
          raise(ArgumentError, "Compression #{compression} is not supported. Use one of " + org.apache.hadoop.hbase.io.compress.Compression::Algorithm.constants.join(' '))
        end
      end
      if arg.include?(ColumnFamilyDescriptorBuilder::COMPRESSION_COMPACT_MINOR)
        compression = arg.delete(ColumnFamilyDescriptorBuilder::COMPRESSION_COMPACT_MINOR).upcase.to_sym
        if org.apache.hadoop.hbase.io.compress.Compression::Algorithm.constants.include?(compression)
          cfdb.setMinorCompactionCompressionType(org.apache.hadoop.hbase.io.compress.Compression::Algorithm.valueOf(compression))
        else
          raise(ArgumentError, "Compression #{compression} is not supported. Use one of " + org.apache.hadoop.hbase.io.compress.Compression::Algorithm.constants.join(' '))
        end
      end
      if arg.include?(ColumnFamilyDescriptorBuilder::STORAGE_POLICY)
        storage_policy = arg.delete(ColumnFamilyDescriptorBuilder::STORAGE_POLICY).upcase
        cfdb.setStoragePolicy(storage_policy)
      end
      if arg.include?(ColumnFamilyDescriptorBuilder::MOB_COMPACT_PARTITION_POLICY)
        mob_partition_policy = arg.delete(ColumnFamilyDescriptorBuilder::MOB_COMPACT_PARTITION_POLICY).upcase.to_sym
        if MobCompactPartitionPolicy.constants.include?(mob_partition_policy)
          cfdb.setMobCompactPartitionPolicy(MobCompactPartitionPolicy.valueOf(mob_partition_policy))
        else
          raise(ArgumentError, "MOB_COMPACT_PARTITION_POLICY #{mob_partition_policy} is not supported. Use one of " + MobCompactPartitionPolicy.constants.join(' '))
        end
      end

      set_user_metadata(cfdb, arg.delete(METADATA)) if arg[METADATA]
      set_descriptor_config(cfdb, arg.delete(CONFIGURATION)) if arg[CONFIGURATION]
      if arg.include?(ColumnFamilyDescriptorBuilder::DFS_REPLICATION)
        cfdb.setDFSReplication(JInteger.valueOf(arg.delete(ColumnFamilyDescriptorBuilder::DFS_REPLICATION)))
      end

      arg.each_key do |unknown_key|
        puts(format('Unknown argument ignored for column family %s: %s', name, unknown_key))
      end

      cfdb.build
    end

    # Apply user metadata to table/column descriptor
    def set_user_metadata(descriptor, metadata)
      raise(ArgumentError, "#{METADATA} must be a Hash type") unless metadata.is_a?(Hash)
      for k, v in metadata
        v = v.to_s unless v.nil?
        descriptor.setValue(k, v)
      end
    end

    #----------------------------------------------------------------------------------------------
    # Take a snapshot of specified table
    def snapshot(table, snapshot_name, *args)
      # Table name should be a string
      raise(ArgumentError, 'Table name must be of type String') unless table.is_a?(String)

      # Snapshot name should be a string
      raise(ArgumentError, 'Snapshot name must be of type String') unless
          snapshot_name.is_a?(String)

      table_name = TableName.valueOf(table)
      if args.empty?
        @admin.snapshot(snapshot_name, table_name)
      else
        args.each do |arg|
          ttl = arg[TTL]
          ttl = ttl ? ttl.to_java(:long) : -1
          snapshot_props = java.util.HashMap.new
          snapshot_props.put("TTL", ttl)
          max_filesize = arg[MAX_FILESIZE]
          max_filesize = max_filesize ? max_filesize.to_java(:long) : -1
          snapshot_props.put("MAX_FILESIZE", max_filesize)
          if arg[SKIP_FLUSH] == true
            @admin.snapshot(snapshot_name, table_name,
                            org.apache.hadoop.hbase.client.SnapshotType::SKIPFLUSH, snapshot_props)
          else
            @admin.snapshot(snapshot_name, table_name, snapshot_props)
          end
        end
      end
    end

    #----------------------------------------------------------------------------------------------
    # Restore specified snapshot
    def restore_snapshot(snapshot_name, restore_acl = false)
      conf = @connection.getConfiguration
      take_fail_safe_snapshot = conf.getBoolean('hbase.snapshot.restore.take.failsafe.snapshot', false)
      @admin.restoreSnapshot(snapshot_name, take_fail_safe_snapshot, restore_acl)
    end

    #----------------------------------------------------------------------------------------------
    # Create a new table by cloning the snapshot content
    def clone_snapshot(snapshot_name, table, restore_acl = false, clone_sft = nil)
      @admin.cloneSnapshot(snapshot_name, TableName.valueOf(table), restore_acl, clone_sft)
    end

    #----------------------------------------------------------------------------------------------
    # Delete specified snapshot
    def delete_snapshot(snapshot_name)
      @admin.deleteSnapshot(snapshot_name)
    end

    #----------------------------------------------------------------------------------------------
    # Deletes the snapshots matching the given regex
    def delete_all_snapshot(regex)
      @admin.deleteSnapshots(Pattern.compile(regex)).to_a
    end

    #----------------------------------------------------------------------------------------------
    # Deletes the table snapshots matching the given regex
    def delete_table_snapshots(tableNameRegex, snapshotNameRegex = '.*')
      @admin.deleteTableSnapshots(Pattern.compile(tableNameRegex),
        Pattern.compile(snapshotNameRegex)).to_a
    end

    #----------------------------------------------------------------------------------------------
    # Returns a list of snapshots
    def list_snapshot(regex = '.*')
      @admin.listSnapshots(Pattern.compile(regex)).to_a
    end

    #----------------------------------------------------------------------------------------------
    # Returns a list of table snapshots
    def list_table_snapshots(tableNameRegex, snapshotNameRegex = '.*')
      @admin.listTableSnapshots(Pattern.compile(tableNameRegex),
        Pattern.compile(snapshotNameRegex)).to_a
    end

    #----------------------------------------------------------------------------------------------
    # Returns the whole ClusterMetrics containing details:
    #
    # hbase version
    # cluster id
    # primary/backup master(s)
    # master's coprocessors
    # live/dead regionservers
    # balancer
    # regions in transition
    def getClusterMetrics
      @admin.getClusterMetrics
    end

    #----------------------------------------------------------------------------------------------
    # Returns a list of regionservers
    def getRegionServers
      @admin.getClusterMetrics.getLiveServerMetrics.keySet.map { |server_name| server_name }
    end

    #----------------------------------------------------------------------------------------------
    # Returns servername corresponding to passed server_name_string
    def getServerName(server_name_string)
      regionservers = getRegionServers

      if ServerName.isFullServerName(server_name_string)
        return ServerName.valueOf(server_name_string)
      else
        name_list = server_name_string.split(',')

        regionservers.each do|sn|
          if name_list[0] == sn.hostname && (name_list[1].nil? ? true : (name_list[1] == sn.port.to_s))
            return sn
          end
        end
      end

      return nil
    end

    #----------------------------------------------------------------------------------------------
    # Returns a list of servernames
    def getServerNames(servers, should_return_all_if_servers_empty)
      regionservers = getRegionServers
      servernames = []

      if servers.empty?
        # if no servers were specified as arguments, get a list of all servers
        if should_return_all_if_servers_empty
          servernames = regionservers
        end
      else
        # Strings replace with ServerName objects in servers array
        i = 0
        while i < servers.length
          server = servers[i]

          if ServerName.isFullServerName(server)
            servernames.push(ServerName.valueOf(server))
          else
            name_list = server.split(',')
            j = 0
            while j < regionservers.length
              sn = regionservers[j]
              if name_list[0] == sn.hostname && (name_list[1].nil? ? true : (name_list[1] == sn.port.to_s))
                servernames.push(sn)
              end
              j += 1
            end
          end
          i += 1
        end
      end

      servernames
    end

    # Apply config specific to a table/column to its descriptor
    def set_descriptor_config(descriptor, config)
      raise(ArgumentError, "#{CONFIGURATION} must be a Hash type") unless config.is_a?(Hash)
      for k, v in config
        v = v.to_s unless v.nil?
        descriptor.setValue(k, v)
      end
    end

    #----------------------------------------------------------------------------------------------
    # Updates the configuration of one regionserver.
    def update_config(serverName)
      @admin.updateConfiguration(ServerName.valueOf(serverName))
    end

    #----------------------------------------------------------------------------------------------
    # Updates the configuration of all the regionservers.
    def update_all_config
      @admin.updateConfiguration
    end

    #----------------------------------------------------------------------------------------------
    # Updates the configuration of all the regionservers in the rsgroup.
    def update_rsgroup_config(groupName)
      @admin.updateConfiguration(groupName)
    end

    #----------------------------------------------------------------------------------------------
    # Returns namespace's structure description
    def describe_namespace(namespace_name)
      namespace = @admin.getNamespaceDescriptor(namespace_name)

      return namespace.to_s unless namespace.nil?

      raise(ArgumentError, "Failed to find namespace named #{namespace_name}")
    end

    #----------------------------------------------------------------------------------------------
    # Returns a list of namespaces in hbase
    def list_namespace(regex = '.*')
      pattern = java.util.regex.Pattern.compile(regex)
      list = @admin.listNamespaces
      list.select { |s| pattern.match(s) }
    end

    #----------------------------------------------------------------------------------------------
    # Returns a list of tables in namespace
    def list_namespace_tables(namespace_name)
      unless namespace_name.nil?
        return @admin.listTableNamesByNamespace(namespace_name).map(&:getQualifierAsString)
      end

      raise(ArgumentError, "Failed to find namespace named #{namespace_name}")
    end

    #----------------------------------------------------------------------------------------------
    # Creates a namespace
    def create_namespace(namespace_name, *args)
      # Fail if table name is not a string
      raise(ArgumentError, 'Namespace name must be of type String') unless namespace_name.is_a?(String)

      # Flatten params array
      args = args.flatten.compact

      # Start defining the table
      nsb = org.apache.hadoop.hbase.NamespaceDescriptor.create(namespace_name)
      args.each do |arg|
        unless arg.is_a?(Hash)
          raise(ArgumentError, "#{arg.class} of #{arg.inspect} is not of Hash or String type")
        end
        for k, v in arg
          v = v.to_s unless v.nil?
          nsb.addConfiguration(k, v)
        end
      end
      @admin.createNamespace(nsb.build)
    end

    #----------------------------------------------------------------------------------------------
    # modify a namespace
    def alter_namespace(namespace_name, *args)
      # Fail if namespace name is not a string
      raise(ArgumentError, 'Namespace name must be of type String') unless namespace_name.is_a?(String)

      nsd = @admin.getNamespaceDescriptor(namespace_name)

      raise(ArgumentError, 'Namespace does not exist') unless nsd
      nsb = org.apache.hadoop.hbase.NamespaceDescriptor.create(nsd)

      # Flatten params array
      args = args.flatten.compact

      # Start defining the table
      args.each do |arg|
        unless arg.is_a?(Hash)
          raise(ArgumentError, "#{arg.class} of #{arg.inspect} is not of Hash type")
        end
        method = arg[METHOD]
        if method == 'unset'
          nsb.removeConfiguration(arg[NAME])
        elsif method == 'set'
          arg.delete(METHOD)
          for k, v in arg
            v = v.to_s unless v.nil?

            nsb.addConfiguration(k, v)
          end
        else
          raise(ArgumentError, "Unknown method #{method}")
        end
      end
      @admin.modifyNamespace(nsb.build)
    end

    #----------------------------------------------------------------------------------------------
    # Get namespace's rsgroup
    def get_namespace_rsgroup(namespace_name)
      # Fail if namespace name is not a string
      raise(ArgumentError, 'Namespace name must be of type String') unless namespace_name.is_a?(String)
      nsd = @admin.getNamespaceDescriptor(namespace_name)
      raise(ArgumentError, 'Namespace does not exist') unless nsd
      nsd.getConfigurationValue("hbase.rsgroup.name")
    end

    #----------------------------------------------------------------------------------------------
    # Drops a table
    def drop_namespace(namespace_name)
      @admin.deleteNamespace(namespace_name)
    end

    #----------------------------------------------------------------------------------------------
    # Get security capabilities
    def get_security_capabilities
      @admin.getSecurityCapabilities
    end

    # List all procedures
    def list_procedures
      @admin.getProcedures
    end

    # List all locks
    def list_locks
      @admin.getLocks
    end

    # Parse arguments and update TableDescriptorBuilder accordingly
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def update_tdb_from_arg(tdb, arg)
      tdb.setErasureCodingPolicy(arg.delete(TableDescriptorBuilder::ERASURE_CODING_POLICY)) \
        if arg.include?(TableDescriptorBuilder::ERASURE_CODING_POLICY)
      tdb.setMaxFileSize(arg.delete(TableDescriptorBuilder::MAX_FILESIZE)) if arg.include?(TableDescriptorBuilder::MAX_FILESIZE)
      tdb.setReadOnly(JBoolean.valueOf(arg.delete(TableDescriptorBuilder::READONLY))) if arg.include?(TableDescriptorBuilder::READONLY)
      tdb.setCompactionEnabled(JBoolean.valueOf(arg.delete(TableDescriptorBuilder::COMPACTION_ENABLED))) if arg.include?(TableDescriptorBuilder::COMPACTION_ENABLED)
      tdb.setSplitEnabled(JBoolean.valueOf(arg.delete(TableDescriptorBuilder::SPLIT_ENABLED))) if arg.include?(TableDescriptorBuilder::SPLIT_ENABLED)
      tdb.setMergeEnabled(JBoolean.valueOf(arg.delete(TableDescriptorBuilder::MERGE_ENABLED))) if arg.include?(TableDescriptorBuilder::MERGE_ENABLED)
      tdb.setNormalizationEnabled(JBoolean.valueOf(arg.delete(TableDescriptorBuilder::NORMALIZATION_ENABLED))) if arg.include?(TableDescriptorBuilder::NORMALIZATION_ENABLED)
      tdb.setNormalizerTargetRegionCount(JInteger.valueOf(arg.delete(TableDescriptorBuilder::NORMALIZER_TARGET_REGION_COUNT))) if arg.include?(TableDescriptorBuilder::NORMALIZER_TARGET_REGION_COUNT)
      # TODO: Keeping backward compatability for NORMALIZER_TARGET_REGION_SIZE with HBASE-25651 change. Can be removed in later version
      if arg.include?(TableDescriptorBuilder::NORMALIZER_TARGET_REGION_SIZE)
        warn 'Use of NORMALIZER_TARGET_REGION_SIZE has been deprecated and will be removed in future version, please use NORMALIZER_TARGET_REGION_SIZE_MB instead'
        tdb.setNormalizerTargetRegionSize(JLong.valueOf(arg.delete(TableDescriptorBuilder::NORMALIZER_TARGET_REGION_SIZE)))
      end
      tdb.setNormalizerTargetRegionSize(JLong.valueOf(arg.delete(TableDescriptorBuilder::NORMALIZER_TARGET_REGION_SIZE_MB))) \
        if arg.include?(TableDescriptorBuilder::NORMALIZER_TARGET_REGION_SIZE_MB)
      tdb.setMemStoreFlushSize(arg.delete(TableDescriptorBuilder::MEMSTORE_FLUSHSIZE)) if arg.include?(TableDescriptorBuilder::MEMSTORE_FLUSHSIZE)
      tdb.setDurability(org.apache.hadoop.hbase.client.Durability.valueOf(arg.delete(TableDescriptorBuilder::DURABILITY))) if arg.include?(TableDescriptorBuilder::DURABILITY)
      tdb.setPriority(JInteger.valueOf(arg.delete(TableDescriptorBuilder::PRIORITY))) if arg.include?(TableDescriptorBuilder::PRIORITY)
      tdb.setFlushPolicyClassName(arg.delete(TableDescriptorBuilder::FLUSH_POLICY)) if arg.include?(TableDescriptorBuilder::FLUSH_POLICY)
      tdb.setRegionMemStoreReplication(JBoolean.valueOf(arg.delete(TableDescriptorBuilder::REGION_MEMSTORE_REPLICATION))) if arg.include?(TableDescriptorBuilder::REGION_MEMSTORE_REPLICATION)
      tdb.setRegionSplitPolicyClassName(arg.delete(TableDescriptorBuilder::SPLIT_POLICY)) if arg.include?(TableDescriptorBuilder::SPLIT_POLICY)
      tdb.setRegionReplication(JInteger.valueOf(arg.delete(TableDescriptorBuilder::REGION_REPLICATION))) if arg.include?(TableDescriptorBuilder::REGION_REPLICATION)
      set_user_metadata(tdb, arg.delete(METADATA)) if arg[METADATA]
      set_descriptor_config(tdb, arg.delete(CONFIGURATION)) if arg[CONFIGURATION]
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    #----------------------------------------------------------------------------------------------
    # clear compaction queues
    def clear_compaction_queues(server_name, queue_name = nil)
      names = %w[long short]
      queues = java.util.HashSet.new
      if queue_name.nil?
        queues.add('long')
        queues.add('short')
      elsif queue_name.is_a?(String)
        queues.add(queue_name)
        unless names.include?(queue_name)
          raise(ArgumentError, "Unknown queue name #{queue_name}")
        end
      elsif queue_name.is_a?(Array)
        queue_name.each do |s|
          queues.add(s)
          unless names.include?(s)
            raise(ArgumentError, "Unknown queue name #{s}")
          end
        end
      else
        raise(ArgumentError, "Unknown queue name #{queue_name}")
      end
      @admin.clearCompactionQueues(ServerName.valueOf(server_name), queues)
    end

    #----------------------------------------------------------------------------------------------
    # list dead region servers
    def list_deadservers
      @admin.listDeadServers.to_a
    end

    #----------------------------------------------------------------------------------------------
    # clear dead region servers
    def clear_deadservers(dead_servers)
      # Flatten params array
      dead_servers = dead_servers.flatten.compact
      if dead_servers.empty?
        servers = list_deadservers
      else
        servers = java.util.ArrayList.new
        dead_servers.each do |s|
          servers.add(ServerName.valueOf(s))
        end
      end
      @admin.clearDeadServers(servers).to_a
    end

    #----------------------------------------------------------------------------------------------
    # list unknown region servers
    def list_unknownservers
      @admin.listUnknownServers.to_a
    end

    #----------------------------------------------------------------------------------------------
    # List live region servers
    def list_liveservers
      @admin.getClusterMetrics.getLiveServerMetrics.keySet.to_a
    end

    #---------------------------------------------------------------------------
    # create a new table by cloning the existent table schema.
    def clone_table_schema(table_name, new_table_name, preserve_splits = true)
      @admin.cloneTableSchema(TableName.valueOf(table_name),
                              TableName.valueOf(new_table_name),
                              preserve_splits)
    end

    #----------------------------------------------------------------------------------------------
    # List decommissioned RegionServers
    def list_decommissioned_regionservers
      @admin.listDecommissionedRegionServers
    end

    #----------------------------------------------------------------------------------------------
    # Retrieve SlowLog Responses from RegionServers
    def get_slowlog_responses(server_names, args, is_large_log = false)
      unless server_names.is_a?(Array) || server_names.is_a?(String)
        raise(ArgumentError,
              "#{server_names.class} of #{server_names.inspect} is not of Array/String type")
      end
      if server_names == '*'
        server_names = getServerNames([], true)
      else
        server_names_list = to_server_names(server_names)
        server_names = getServerNames(server_names_list, false)
      end
      filter_params = get_filter_params(args)
      if args.key? 'LIMIT'
        limit = args['LIMIT']
      else
        limit = 10
      end
      if is_large_log
        log_type = 'LARGE_LOG'
      else
        log_type = 'SLOW_LOG'
      end
      log_dest = org.apache.hadoop.hbase.client.ServerType::REGION_SERVER
      server_names_set = java.util.HashSet.new(server_names)
      slow_log_responses = @admin.getLogEntries(server_names_set, log_type, log_dest, limit,
                                                filter_params)
      slow_log_responses_arr = []
      slow_log_responses.each { |slow_log_response|
        slow_log_responses_arr << slow_log_response.toJsonPrettyPrint
      }
      slow_log_responses_arr
    end

    def get_filter_params(args)
      filter_params = java.util.HashMap.new
      if args.key? 'REGION_NAME'
        region_name = args['REGION_NAME']
        filter_params.put('regionName', region_name)
      end
      if args.key? 'TABLE_NAME'
        table_name = args['TABLE_NAME']
        filter_params.put('tableName', table_name)
      end
      if args.key? 'CLIENT_IP'
        client_address = args['CLIENT_IP']
        filter_params.put('clientAddress', client_address)
      end
      if args.key? 'USER'
        user = args['USER']
        filter_params.put('userName', user)
      end
      if args.key? 'FILTER_BY_OP'
        filter_by_op = args['FILTER_BY_OP']
        if filter_by_op != 'OR' && filter_by_op != 'AND'
          raise(ArgumentError, "FILTER_BY_OP should be either OR / AND")
        end
        if filter_by_op == 'AND'
          filter_params.put('filterByOperator', 'AND')
        end
      end
      filter_params
    end

    #----------------------------------------------------------------------------------------------
    # Clears SlowLog Responses from RegionServers
    def clear_slowlog_responses(server_names)
      unless server_names.nil? || server_names.is_a?(Array) || server_names.is_a?(String)
        raise(ArgumentError,
              "#{server_names.class} of #{server_names.inspect} is not of correct type")
      end
      if server_names.nil?
        server_names = getServerNames([], true)
      else
        server_names_list = to_server_names(server_names)
        server_names = getServerNames(server_names_list, false)
      end
      clear_log_responses = @admin.clearSlowLogResponses(java.util.HashSet.new(server_names))
      clear_log_success_count = 0
      clear_log_responses.each do |response|
        if response
          clear_log_success_count += 1
        end
      end
      puts 'Cleared Slowlog responses from ' \
           "#{clear_log_success_count}/#{clear_log_responses.size} RegionServers"
    end

    #----------------------------------------------------------------------------------------------
    # Decommission a list of region servers, optionally offload corresponding regions
    def decommission_regionservers(host_or_servers, should_offload)
      # Fail if host_or_servers is neither a string nor an array
      unless host_or_servers.is_a?(Array) || host_or_servers.is_a?(String)
        raise(ArgumentError,
             "#{host_or_servers.class} of #{host_or_servers.inspect} is not of Array/String type")
      end

      # Fail if should_offload is neither a TrueClass/FalseClass nor a string
      unless (!!should_offload == should_offload) || should_offload.is_a?(String)
        raise(ArgumentError, "#{should_offload} is not a boolean value")
      end

      # If a string is passed, convert  it to an array
      _host_or_servers =  host_or_servers.is_a?(Array) ?
                          host_or_servers :
                          java.util.Arrays.asList(host_or_servers)

      # Retrieve the server names corresponding to passed _host_or_servers list
      server_names = getServerNames(_host_or_servers, false)

      # Fail, if we can not find any server(s) corresponding to the passed host_or_servers
      if server_names.empty?
        raise(ArgumentError,
             "Could not find any server(s) with specified name(s): #{host_or_servers}")
      end

      @admin.decommissionRegionServers(server_names,
                                       java.lang.Boolean.valueOf(should_offload))
    end

    #----------------------------------------------------------------------------------------------
    # Recommission a region server, optionally load a list of passed regions
    def recommission_regionserver(server_name_string, encoded_region_names)
      # Fail if server_name_string is not a string
      unless server_name_string.is_a?(String)
        raise(ArgumentError,
             "#{server_name_string.class} of #{server_name_string.inspect} is not of String type")
      end

      # Fail if encoded_region_names is not an array
      unless encoded_region_names.is_a?(Array)
        raise(ArgumentError,
             "#{encoded_region_names.class} of #{encoded_region_names.inspect} is not of Array type")
      end

      # Convert encoded_region_names from string to bytes (element-wise)
      region_names_in_bytes = encoded_region_names
                              .map {|region_name| region_name.to_java_bytes}
                              .compact

      # Retrieve the server name corresponding to the passed server_name_string
      server_name = getServerName(server_name_string)

      # Fail if we can not find a server corresponding to the passed server_name_string
      if server_name.nil?
        raise(ArgumentError,
             "Could not find any server with name #{server_name_string}")
      end

      @admin.recommissionRegionServer(server_name, region_names_in_bytes)
    end

    #----------------------------------------------------------------------------------------------
    # Retrieve latest balancer decisions made by LoadBalancers
    def get_balancer_decisions(args)
      if args.key? 'LIMIT'
        limit = args['LIMIT']
      else
        limit = 250
      end
      log_type = 'BALANCER_DECISION'
      log_dest = org.apache.hadoop.hbase.client.ServerType::MASTER
      balancer_decisions_responses = @admin.getLogEntries(nil, log_type, log_dest, limit, nil)
      balancer_decisions_resp_arr = []
      balancer_decisions_responses.each { |balancer_dec_resp|
        balancer_decisions_resp_arr << balancer_dec_resp.toJsonPrettyPrint
      }
      balancer_decisions_resp_arr
    end

    #----------------------------------------------------------------------------------------------
    # Retrieve latest balancer rejections made by LoadBalancers
    def get_balancer_rejections(args)
      if args.key? 'LIMIT'
        limit = args['LIMIT']
      else
        limit = 250
      end

      log_type = 'BALANCER_REJECTION'
      log_dest = org.apache.hadoop.hbase.client.ServerType::MASTER
      balancer_rejections_responses = @admin.getLogEntries(nil, log_type, log_dest, limit, nil)
      balancer_rejections_resp_arr = []
      balancer_rejections_responses.each { |balancer_dec_resp|
        balancer_rejections_resp_arr << balancer_dec_resp.toJsonPrettyPrint
      }
      balancer_rejections_resp_arr
    end

    #----------------------------------------------------------------------------------------------
    # Stop the active Master
    def stop_master
      @admin.stopMaster
    end

    # Stop the given RegionServer
    def stop_regionserver(hostport)
      @admin.stopRegionServer(hostport)
    end

    #----------------------------------------------------------------------------------------------
    # Get list of server names
    def to_server_names(server_names)
      if server_names.is_a?(Array)
        server_names
      else
        java.util.Arrays.asList(server_names)
      end
    end

    #----------------------------------------------------------------------------------------------
    # Change table's sft
    def modify_table_sft(tableName, sft)
      @admin.modifyTableStoreFileTracker(tableName, sft)
    end

    #----------------------------------------------------------------------------------------------
    # Change table column family's sft
    def modify_table_family_sft(tableName, family_bytes, sft)
      @admin.modifyColumnFamilyStoreFileTracker(tableName, family_bytes, sft)
    end

    #----------------------------------------------------------------------------------------------
    # Flush master local region
    def flush_master_store()
      @admin.flushMasterStore()
    end

    #----------------------------------------------------------------------------------------------
    # Returns a list of enable or disabled tables in hbase
    def list_tables_by_state(isEnabled)
      @admin.listTableNamesByState(isEnabled).map(&:getNameAsString)
    end
  end
  # rubocop:enable Metrics/ClassLength
end
