/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.hadoop.hbase.master.janitor;

import static org.apache.hadoop.hbase.util.HFileArchiveTestingUtil.assertArchiveEqualToOriginal;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.spy;
import static org.mockito.Mockito.when;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.SortedMap;
import java.util.TreeMap;
import java.util.concurrent.atomic.AtomicBoolean;
import org.apache.hadoop.fs.FSDataOutputStream;
import org.apache.hadoop.fs.FileStatus;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.hbase.HBaseClassTestRule;
import org.apache.hadoop.hbase.HBaseTestingUtil;
import org.apache.hadoop.hbase.HConstants;
import org.apache.hadoop.hbase.MetaMockingUtil;
import org.apache.hadoop.hbase.TableName;
import org.apache.hadoop.hbase.client.ColumnFamilyDescriptor;
import org.apache.hadoop.hbase.client.ColumnFamilyDescriptorBuilder;
import org.apache.hadoop.hbase.client.RegionInfo;
import org.apache.hadoop.hbase.client.RegionInfoBuilder;
import org.apache.hadoop.hbase.client.Result;
import org.apache.hadoop.hbase.client.TableDescriptor;
import org.apache.hadoop.hbase.client.TableDescriptorBuilder;
import org.apache.hadoop.hbase.io.Reference;
import org.apache.hadoop.hbase.master.MasterFileSystem;
import org.apache.hadoop.hbase.master.MasterServices;
import org.apache.hadoop.hbase.master.assignment.MockMasterServices;
import org.apache.hadoop.hbase.master.janitor.CatalogJanitor.SplitParentFirstComparator;
import org.apache.hadoop.hbase.procedure2.ProcedureTestingUtility;
import org.apache.hadoop.hbase.regionserver.ChunkCreator;
import org.apache.hadoop.hbase.regionserver.HRegionFileSystem;
import org.apache.hadoop.hbase.regionserver.MemStoreLAB;
import org.apache.hadoop.hbase.regionserver.StoreContext;
import org.apache.hadoop.hbase.regionserver.storefiletracker.StoreFileTracker;
import org.apache.hadoop.hbase.regionserver.storefiletracker.StoreFileTrackerFactory;
import org.apache.hadoop.hbase.testclassification.MasterTests;
import org.apache.hadoop.hbase.testclassification.MediumTests;
import org.apache.hadoop.hbase.util.Bytes;
import org.apache.hadoop.hbase.util.CommonFSUtils;
import org.apache.hadoop.hbase.util.EnvironmentEdgeManager;
import org.apache.hadoop.hbase.util.HFileArchiveUtil;
import org.junit.After;
import org.junit.Before;
import org.junit.BeforeClass;
import org.junit.ClassRule;
import org.junit.Rule;
import org.junit.Test;
import org.junit.experimental.categories.Category;
import org.junit.rules.TestName;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@Category({ MasterTests.class, MediumTests.class })
public class TestCatalogJanitor {

  @ClassRule
  public static final HBaseClassTestRule CLASS_RULE =
    HBaseClassTestRule.forClass(TestCatalogJanitor.class);

  private static final Logger LOG = LoggerFactory.getLogger(TestCatalogJanitor.class);

  private static final HBaseTestingUtil HTU = new HBaseTestingUtil();

  @Rule
  public final TestName name = new TestName();

  private MockMasterServices masterServices;
  private CatalogJanitor janitor;

  @BeforeClass
  public static void beforeClass() throws Exception {
    ChunkCreator.initialize(MemStoreLAB.CHUNK_SIZE_DEFAULT, false, 0, 0, 0, null,
      MemStoreLAB.INDEX_CHUNK_SIZE_PERCENTAGE_DEFAULT);
  }

  @Before
  public void setup() throws Exception {
    setRootDirAndCleanIt(HTU, this.name.getMethodName());
    this.masterServices = new MockMasterServices(HTU.getConfiguration());
    this.masterServices.start(10, null);
    this.janitor = new CatalogJanitor(masterServices);
  }

  @After
  public void teardown() {
    this.janitor.shutdown(true);
    this.masterServices.stop("DONE");
  }

  private RegionInfo createRegionInfo(TableName tableName, byte[] startKey, byte[] endKey) {
    return createRegionInfo(tableName, startKey, endKey, false);
  }

  private RegionInfo createRegionInfo(TableName tableName, byte[] startKey, byte[] endKey,
    boolean split) {
    return RegionInfoBuilder.newBuilder(tableName).setStartKey(startKey).setEndKey(endKey)
      .setSplit(split).build();
  }

  @Test
  public void testCleanMerge() throws IOException {
    TableDescriptor td = createTableDescriptorForCurrentMethod();
    // Create regions.
    RegionInfo merged =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("eee"));
    RegionInfo parenta =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("ccc"));
    RegionInfo parentb =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), Bytes.toBytes("eee"));

    List<RegionInfo> parents = new ArrayList<>();
    parents.add(parenta);
    parents.add(parentb);

    Path rootdir = this.masterServices.getMasterFileSystem().getRootDir();
    Path tabledir = CommonFSUtils.getTableDir(rootdir, td.getTableName());
    Path storedir =
      HRegionFileSystem.getStoreHomedir(tabledir, merged, td.getColumnFamilies()[0].getName());

    Path parentaRef =
      createMergeReferenceFile(storedir, tabledir, td.getColumnFamilies()[0], merged, parenta);
    Path parentbRef =
      createMergeReferenceFile(storedir, tabledir, td.getColumnFamilies()[0], merged, parentb);

    // references exist, should not clean
    assertFalse(CatalogJanitor.cleanMergeRegion(masterServices, merged, parents));

    masterServices.getMasterFileSystem().getFileSystem().delete(parentaRef, false);

    // one reference still exists, should not clean
    assertFalse(CatalogJanitor.cleanMergeRegion(masterServices, merged, parents));

    masterServices.getMasterFileSystem().getFileSystem().delete(parentbRef, false);

    // all references removed, should clean
    assertTrue(CatalogJanitor.cleanMergeRegion(masterServices, merged, parents));
  }

  @Test
  public void testDontCleanMergeIfFileSystemException() throws IOException {
    TableDescriptor td = createTableDescriptorForCurrentMethod();
    // Create regions.
    RegionInfo merged =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("eee"));
    RegionInfo parenta =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("ccc"));
    RegionInfo parentb =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), Bytes.toBytes("eee"));

    List<RegionInfo> parents = new ArrayList<>();
    parents.add(parenta);
    parents.add(parentb);

    Path rootdir = this.masterServices.getMasterFileSystem().getRootDir();
    Path tabledir = CommonFSUtils.getTableDir(rootdir, td.getTableName());
    Path storedir =
      HRegionFileSystem.getStoreHomedir(tabledir, merged, td.getColumnFamilies()[0].getName());
    createMergeReferenceFile(storedir, tabledir, td.getColumnFamilies()[0], merged, parenta);

    MasterServices mockedMasterServices = spy(masterServices);
    MasterFileSystem mockedMasterFileSystem = spy(masterServices.getMasterFileSystem());
    FileSystem mockedFileSystem = spy(masterServices.getMasterFileSystem().getFileSystem());

    when(mockedMasterServices.getMasterFileSystem()).thenReturn(mockedMasterFileSystem);
    when(mockedMasterFileSystem.getFileSystem()).thenReturn(mockedFileSystem);

    // throw on the first exists check
    doThrow(new IOException("Some exception")).when(mockedFileSystem).exists(any());

    assertFalse(CatalogJanitor.cleanMergeRegion(mockedMasterServices, merged, parents));

    // throw on the second exists check (within HRegionfileSystem)
    AtomicBoolean returned = new AtomicBoolean(false);
    doAnswer(invocationOnMock -> {
      if (!returned.get()) {
        returned.set(true);
        return masterServices.getMasterFileSystem().getFileSystem()
          .exists(invocationOnMock.getArgument(0));
      }
      throw new IOException("Some exception");
    }).when(mockedFileSystem).exists(any());

    assertFalse(CatalogJanitor.cleanMergeRegion(mockedMasterServices, merged, parents));
  }

  private Path createMergeReferenceFile(Path storeDir, Path tableDir,
    ColumnFamilyDescriptor columnFamilyDescriptor, RegionInfo mergedRegion, RegionInfo parentRegion)
    throws IOException {
    Reference ref = Reference.createTopReference(mergedRegion.getStartKey());
    long now = EnvironmentEdgeManager.currentTime();
    // Reference name has this format: StoreFile#REF_NAME_PARSER
    Path p = new Path(storeDir, Long.toString(now) + "." + parentRegion.getEncodedName());
    FileSystem fs = this.masterServices.getMasterFileSystem().getFileSystem();
    HRegionFileSystem mergedRegionFS =
      HRegionFileSystem.create(fs.getConf(), fs, tableDir, mergedRegion);
    StoreContext storeContext =
      StoreContext.getBuilder().withColumnFamilyDescriptor(columnFamilyDescriptor)
        .withFamilyStoreDirectoryPath(storeDir).withRegionFileSystem(mergedRegionFS).build();
    StoreFileTracker sft = StoreFileTrackerFactory.create(fs.getConf(), false, storeContext);
    sft.createReference(ref, p);
    return p;
  }

  /**
   * Test clearing a split parent.
   */
  @Test
  public void testCleanParent() throws IOException, InterruptedException {
    TableDescriptor td = createTableDescriptorForCurrentMethod();
    // Create regions.
    RegionInfo parent =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("eee"));
    RegionInfo splita =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("ccc"));
    RegionInfo splitb =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), Bytes.toBytes("eee"));
    // Test that when both daughter regions are in place, that we do not remove the parent.
    Result r = createResult(parent, splita, splitb);
    // Add a reference under splitA directory so we don't clear out the parent.
    Path rootdir = this.masterServices.getMasterFileSystem().getRootDir();
    Path tabledir = CommonFSUtils.getTableDir(rootdir, td.getTableName());
    Path parentdir = new Path(tabledir, parent.getEncodedName());
    Path storedir =
      HRegionFileSystem.getStoreHomedir(tabledir, splita, td.getColumnFamilies()[0].getName());
    Reference ref = Reference.createTopReference(Bytes.toBytes("ccc"));
    long now = EnvironmentEdgeManager.currentTime();
    // Reference name has this format: StoreFile#REF_NAME_PARSER
    Path p = new Path(storedir, Long.toString(now) + "." + parent.getEncodedName());
    FileSystem fs = this.masterServices.getMasterFileSystem().getFileSystem();
    HRegionFileSystem regionFS =
      HRegionFileSystem.create(this.masterServices.getConfiguration(), fs, tabledir, splita);
    StoreContext storeContext =
      StoreContext.getBuilder().withColumnFamilyDescriptor(td.getColumnFamilies()[0])
        .withFamilyStoreDirectoryPath(storedir).withRegionFileSystem(regionFS).build();
    StoreFileTracker sft =
      StoreFileTrackerFactory.create(this.masterServices.getConfiguration(), false, storeContext);
    sft.createReference(ref, p);
    assertTrue(fs.exists(p));
    LOG.info("Created reference " + p);
    // Add a parentdir for kicks so can check it gets removed by the catalogjanitor.
    fs.mkdirs(parentdir);
    assertFalse(CatalogJanitor.cleanParent(masterServices, parent, r));
    ProcedureTestingUtility.waitAllProcedures(masterServices.getMasterProcedureExecutor());
    assertTrue(fs.exists(parentdir));
    // Remove the reference file and try again.
    assertTrue(fs.delete(p, true));
    assertTrue(CatalogJanitor.cleanParent(masterServices, parent, r));
    // Parent cleanup is run async as a procedure. Make sure parentdir is removed.
    ProcedureTestingUtility.waitAllProcedures(masterServices.getMasterProcedureExecutor());
    assertTrue(!fs.exists(parentdir));
  }

  /**
   * Make sure parent gets cleaned up even if daughter is cleaned up before it.
   */
  @Test
  public void testParentCleanedEvenIfDaughterGoneFirst() throws IOException, InterruptedException {
    parentWithSpecifiedEndKeyCleanedEvenIfDaughterGoneFirst(this.name.getMethodName(),
      Bytes.toBytes("eee"));
  }

  /**
   * Make sure last parent with empty end key gets cleaned up even if daughter is cleaned up before
   * it.
   */
  @Test
  public void testLastParentCleanedEvenIfDaughterGoneFirst()
    throws IOException, InterruptedException {
    parentWithSpecifiedEndKeyCleanedEvenIfDaughterGoneFirst(this.name.getMethodName(), new byte[0]);
  }

  /**
   * @return A TableDescriptor with a tableName of current method name and a column family that is
   *         MockMasterServices.DEFAULT_COLUMN_FAMILY_NAME)
   */
  private TableDescriptor createTableDescriptorForCurrentMethod() {
    ColumnFamilyDescriptor columnFamilyDescriptor = ColumnFamilyDescriptorBuilder
      .newBuilder(Bytes.toBytes(MockMasterServices.DEFAULT_COLUMN_FAMILY_NAME)).build();
    return TableDescriptorBuilder.newBuilder(TableName.valueOf(this.name.getMethodName()))
      .setColumnFamily(columnFamilyDescriptor).build();
  }

  /**
   * Make sure parent with specified end key gets cleaned up even if daughter is cleaned up before
   * it.
   * @param rootDir    the test case name, used as the HBase testing utility root
   * @param lastEndKey the end key of the split parent
   */
  private void parentWithSpecifiedEndKeyCleanedEvenIfDaughterGoneFirst(final String rootDir,
    final byte[] lastEndKey) throws IOException, InterruptedException {
    TableDescriptor td = createTableDescriptorForCurrentMethod();
    // Create regions: aaa->{lastEndKey}, aaa->ccc, aaa->bbb, bbb->ccc, etc.
    RegionInfo parent = createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), lastEndKey);
    // Sleep a second else the encoded name on these regions comes out
    // same for all with same start key and made in same second.
    Thread.sleep(1001);

    // Daughter a
    RegionInfo splita =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("ccc"));
    Thread.sleep(1001);
    // Make daughters of daughter a; splitaa and splitab.
    RegionInfo splitaa =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("bbb"));
    RegionInfo splitab =
      createRegionInfo(td.getTableName(), Bytes.toBytes("bbb"), Bytes.toBytes("ccc"));

    // Daughter b
    RegionInfo splitb = createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), lastEndKey);
    Thread.sleep(1001);
    // Make Daughters of daughterb; splitba and splitbb.
    RegionInfo splitba =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), Bytes.toBytes("ddd"));
    RegionInfo splitbb = createRegionInfo(td.getTableName(), Bytes.toBytes("ddd"), lastEndKey);

    // First test that our Comparator works right up in CatalogJanitor.
    SortedMap<RegionInfo, Result> regions =
      new TreeMap<>(new CatalogJanitor.SplitParentFirstComparator());
    // Now make sure that this regions map sorts as we expect it to.
    regions.put(parent, createResult(parent, splita, splitb));
    regions.put(splitb, createResult(splitb, splitba, splitbb));
    regions.put(splita, createResult(splita, splitaa, splitab));
    // Assert its properly sorted.
    int index = 0;
    for (Map.Entry<RegionInfo, Result> e : regions.entrySet()) {
      if (index == 0) {
        assertTrue(e.getKey().getEncodedName().equals(parent.getEncodedName()));
      } else if (index == 1) {
        assertTrue(e.getKey().getEncodedName().equals(splita.getEncodedName()));
      } else if (index == 2) {
        assertTrue(e.getKey().getEncodedName().equals(splitb.getEncodedName()));
      }
      index++;
    }

    // Now play around with the cleanParent function. Create a ref from splita up to the parent.
    Path splitaRef =
      createReferences(this.masterServices, td, parent, splita, Bytes.toBytes("ccc"), false);
    // Make sure actual super parent sticks around because splita has a ref.
    assertFalse(CatalogJanitor.cleanParent(masterServices, parent, regions.get(parent)));

    // splitba, and split bb, do not have dirs in fs. That means that if
    // we test splitb, it should get cleaned up.
    assertTrue(CatalogJanitor.cleanParent(masterServices, splitb, regions.get(splitb)));

    // Now remove ref from splita to parent... so parent can be let go and so
    // the daughter splita can be split (can't split if still references).
    // BUT make the timing such that the daughter gets cleaned up before we
    // can get a chance to let go of the parent.
    FileSystem fs = FileSystem.get(HTU.getConfiguration());
    assertTrue(fs.delete(splitaRef, true));
    // Create the refs from daughters of splita.
    Path splitaaRef =
      createReferences(this.masterServices, td, splita, splitaa, Bytes.toBytes("bbb"), false);
    Path splitabRef =
      createReferences(this.masterServices, td, splita, splitab, Bytes.toBytes("bbb"), true);

    // Test splita. It should stick around because references from splitab, etc.
    assertFalse(CatalogJanitor.cleanParent(masterServices, splita, regions.get(splita)));

    // Now clean up parent daughter first. Remove references from its daughters.
    assertTrue(fs.delete(splitaaRef, true));
    assertTrue(fs.delete(splitabRef, true));
    assertTrue(CatalogJanitor.cleanParent(masterServices, splita, regions.get(splita)));

    // Super parent should get cleaned up now both splita and splitb are gone.
    assertTrue(CatalogJanitor.cleanParent(masterServices, parent, regions.get(parent)));
  }

  /**
   * CatalogJanitor.scan() should not clean parent regions if their own parents are still
   * referencing them. This ensures that grandparent regions do not point to deleted parent regions.
   */
  @Test
  public void testScanDoesNotCleanRegionsWithExistingParents() throws Exception {
    TableDescriptor td = createTableDescriptorForCurrentMethod();
    // Create regions: aaa->{lastEndKey}, aaa->ccc, aaa->bbb, bbb->ccc, etc.

    // Parent
    RegionInfo parent =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), HConstants.EMPTY_BYTE_ARRAY, true);
    // Sleep a second else the encoded name on these regions comes out
    // same for all with same start key and made in same second.
    Thread.sleep(1001);

    // Daughter a
    RegionInfo splita =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("ccc"), true);
    Thread.sleep(1001);

    // Make daughters of daughter a; splitaa and splitab.
    RegionInfo splitaa =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("bbb"), false);
    RegionInfo splitab =
      createRegionInfo(td.getTableName(), Bytes.toBytes("bbb"), Bytes.toBytes("ccc"), false);

    // Daughter b
    RegionInfo splitb =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), HConstants.EMPTY_BYTE_ARRAY);
    Thread.sleep(1001);

    // Parent has daughters splita and splitb. Splita has daughters splitaa and splitab.
    final Map<RegionInfo, Result> splitParents = new TreeMap<>(new SplitParentFirstComparator());
    splitParents.put(parent, createResult(parent, splita, splitb));
    // simulate that splita goes offline when it is split
    splita = RegionInfoBuilder.newBuilder(splita).setOffline(true).build();
    splitParents.put(splita, createResult(splita, splitaa, splitab));

    final Map<RegionInfo, Result> mergedRegions = new TreeMap<>();
    CatalogJanitor spy = spy(this.janitor);

    CatalogJanitorReport report = new CatalogJanitorReport();
    report.count = 10;
    report.mergedRegions.putAll(mergedRegions);
    report.splitParents.putAll(splitParents);

    doReturn(report).when(spy).scanForReport();

    // Create ref from splita to parent
    LOG.info("parent=" + parent.getShortNameToLog() + ", splita=" + splita.getShortNameToLog());
    Path splitaRef =
      createReferences(this.masterServices, td, parent, splita, Bytes.toBytes("ccc"), false);
    LOG.info("Created reference " + splitaRef);

    // Parent and splita should not be removed because a reference from splita to parent.
    int gcs = spy.scan();
    assertEquals(0, gcs);

    // Now delete the ref
    FileSystem fs = FileSystem.get(HTU.getConfiguration());
    assertTrue(fs.delete(splitaRef, true));

    // now, both parent, and splita can be deleted
    gcs = spy.scan();
    assertEquals(2, gcs);
  }

  /**
   * Test that we correctly archive all the storefiles when a region is deleted
   */
  @Test
  public void testSplitParentFirstComparator() {
    SplitParentFirstComparator comp = new SplitParentFirstComparator();
    TableDescriptor td = createTableDescriptorForCurrentMethod();

    /*
     * Region splits: rootRegion --- firstRegion --- firstRegiona | |- firstRegionb | |- lastRegion
     * --- lastRegiona --- lastRegionaa | |- lastRegionab |- lastRegionb rootRegion : [] - []
     * firstRegion : [] - bbb lastRegion : bbb - [] firstRegiona : [] - aaa firstRegionb : aaa - bbb
     * lastRegiona : bbb - ddd lastRegionb : ddd - []
     */

    // root region
    RegionInfo rootRegion = createRegionInfo(td.getTableName(), HConstants.EMPTY_START_ROW,
      HConstants.EMPTY_END_ROW, true);
    RegionInfo firstRegion =
      createRegionInfo(td.getTableName(), HConstants.EMPTY_START_ROW, Bytes.toBytes("bbb"), true);
    RegionInfo lastRegion =
      createRegionInfo(td.getTableName(), Bytes.toBytes("bbb"), HConstants.EMPTY_END_ROW, true);

    assertTrue(comp.compare(rootRegion, rootRegion) == 0);
    assertTrue(comp.compare(firstRegion, firstRegion) == 0);
    assertTrue(comp.compare(lastRegion, lastRegion) == 0);
    assertTrue(comp.compare(rootRegion, firstRegion) < 0);
    assertTrue(comp.compare(rootRegion, lastRegion) < 0);
    assertTrue(comp.compare(firstRegion, lastRegion) < 0);

    // first region split into a, b
    RegionInfo firstRegiona =
      createRegionInfo(td.getTableName(), HConstants.EMPTY_START_ROW, Bytes.toBytes("aaa"), true);
    RegionInfo firstRegionb =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("bbb"), true);
    // last region split into a, b
    RegionInfo lastRegiona =
      createRegionInfo(td.getTableName(), Bytes.toBytes("bbb"), Bytes.toBytes("ddd"), true);
    RegionInfo lastRegionb =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ddd"), HConstants.EMPTY_END_ROW, true);

    assertTrue(comp.compare(firstRegiona, firstRegiona) == 0);
    assertTrue(comp.compare(firstRegionb, firstRegionb) == 0);
    assertTrue(comp.compare(rootRegion, firstRegiona) < 0);
    assertTrue(comp.compare(rootRegion, firstRegionb) < 0);
    assertTrue(comp.compare(firstRegion, firstRegiona) < 0);
    assertTrue(comp.compare(firstRegion, firstRegionb) < 0);
    assertTrue(comp.compare(firstRegiona, firstRegionb) < 0);

    assertTrue(comp.compare(lastRegiona, lastRegiona) == 0);
    assertTrue(comp.compare(lastRegionb, lastRegionb) == 0);
    assertTrue(comp.compare(rootRegion, lastRegiona) < 0);
    assertTrue(comp.compare(rootRegion, lastRegionb) < 0);
    assertTrue(comp.compare(lastRegion, lastRegiona) < 0);
    assertTrue(comp.compare(lastRegion, lastRegionb) < 0);
    assertTrue(comp.compare(lastRegiona, lastRegionb) < 0);

    assertTrue(comp.compare(firstRegiona, lastRegiona) < 0);
    assertTrue(comp.compare(firstRegiona, lastRegionb) < 0);
    assertTrue(comp.compare(firstRegionb, lastRegiona) < 0);
    assertTrue(comp.compare(firstRegionb, lastRegionb) < 0);

    RegionInfo lastRegionaa =
      createRegionInfo(td.getTableName(), Bytes.toBytes("bbb"), Bytes.toBytes("ccc"), false);
    RegionInfo lastRegionab =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), Bytes.toBytes("ddd"), false);

    assertTrue(comp.compare(lastRegiona, lastRegionaa) < 0);
    assertTrue(comp.compare(lastRegiona, lastRegionab) < 0);
    assertTrue(comp.compare(lastRegionaa, lastRegionab) < 0);
  }

  @Test
  public void testArchiveOldRegion() throws Exception {
    // Create regions.
    TableDescriptor td = createTableDescriptorForCurrentMethod();
    RegionInfo parent =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("eee"));
    RegionInfo splita =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("ccc"));
    RegionInfo splitb =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), Bytes.toBytes("eee"));

    // Test that when both daughter regions are in place, that we do not
    // remove the parent.
    Result parentMetaRow = createResult(parent, splita, splitb);
    FileSystem fs = FileSystem.get(HTU.getConfiguration());
    Path rootdir = this.masterServices.getMasterFileSystem().getRootDir();
    // have to set the root directory since we use it in HFileDisposer to figure out to get to the
    // archive directory. Otherwise, it just seems to pick the first root directory it can find (so
    // the single test passes, but when the full suite is run, things get borked).
    CommonFSUtils.setRootDir(fs.getConf(), rootdir);
    Path tabledir = CommonFSUtils.getTableDir(rootdir, td.getTableName());
    Path storedir =
      HRegionFileSystem.getStoreHomedir(tabledir, parent, td.getColumnFamilies()[0].getName());
    Path storeArchive = HFileArchiveUtil.getStoreArchivePath(this.masterServices.getConfiguration(),
      parent, tabledir, td.getColumnFamilies()[0].getName());
    LOG.debug("Table dir:" + tabledir);
    LOG.debug("Store dir:" + storedir);
    LOG.debug("Store archive dir:" + storeArchive);

    // add a couple of store files that we can check for
    FileStatus[] mockFiles = addMockStoreFiles(2, this.masterServices, storedir);
    // get the current store files for comparison
    FileStatus[] storeFiles = fs.listStatus(storedir);
    int index = 0;
    for (FileStatus file : storeFiles) {
      LOG.debug("Have store file:" + file.getPath());
      assertEquals("Got unexpected store file", mockFiles[index].getPath(),
        storeFiles[index].getPath());
      index++;
    }

    // do the cleaning of the parent
    assertTrue(CatalogJanitor.cleanParent(masterServices, parent, parentMetaRow));
    Path parentDir = new Path(tabledir, parent.getEncodedName());
    // Cleanup procedure runs async. Wait till it done.
    ProcedureTestingUtility.waitAllProcedures(masterServices.getMasterProcedureExecutor());
    assertTrue(!fs.exists(parentDir));
    LOG.debug("Finished cleanup of parent region");

    // and now check to make sure that the files have actually been archived
    FileStatus[] archivedStoreFiles = fs.listStatus(storeArchive);
    logFiles("archived files", storeFiles);
    logFiles("archived files", archivedStoreFiles);

    assertArchiveEqualToOriginal(storeFiles, archivedStoreFiles, fs);

    // cleanup
    CommonFSUtils.delete(fs, rootdir, true);
  }

  /**
   * @param description description of the files for logging
   * @param storeFiles  the status of the files to log
   */
  private void logFiles(String description, FileStatus[] storeFiles) {
    LOG.debug("Current " + description + ": ");
    for (FileStatus file : storeFiles) {
      LOG.debug(Objects.toString(file.getPath()));
    }
  }

  /**
   * Test that if a store file with the same name is present as those already backed up cause the
   * already archived files to be timestamped backup
   */
  @Test
  public void testDuplicateHFileResolution() throws Exception {
    TableDescriptor td = createTableDescriptorForCurrentMethod();

    // Create regions.
    RegionInfo parent =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("eee"));
    RegionInfo splita =
      createRegionInfo(td.getTableName(), Bytes.toBytes("aaa"), Bytes.toBytes("ccc"));
    RegionInfo splitb =
      createRegionInfo(td.getTableName(), Bytes.toBytes("ccc"), Bytes.toBytes("eee"));
    // Test that when both daughter regions are in place, that we do not
    // remove the parent.
    Result r = createResult(parent, splita, splitb);
    FileSystem fs = FileSystem.get(HTU.getConfiguration());
    Path rootdir = this.masterServices.getMasterFileSystem().getRootDir();
    // Have to set the root directory since we use it in HFileDisposer to figure out to get to the
    // archive directory. Otherwise, it just seems to pick the first root directory it can find (so
    // the single test passes, but when the full suite is run, things get borked).
    CommonFSUtils.setRootDir(fs.getConf(), rootdir);
    Path tabledir = CommonFSUtils.getTableDir(rootdir, parent.getTable());
    Path storedir =
      HRegionFileSystem.getStoreHomedir(tabledir, parent, td.getColumnFamilies()[0].getName());
    LOG.info("Old root:" + rootdir);
    LOG.info("Old table:" + tabledir);
    LOG.info("Old store:" + storedir);

    Path storeArchive = HFileArchiveUtil.getStoreArchivePath(this.masterServices.getConfiguration(),
      parent, tabledir, td.getColumnFamilies()[0].getName());
    LOG.info("Old archive:" + storeArchive);

    // enable archiving, make sure that files get archived
    addMockStoreFiles(2, this.masterServices, storedir);
    // get the current store files for comparison
    FileStatus[] storeFiles = fs.listStatus(storedir);
    // Do the cleaning of the parent
    assertTrue(CatalogJanitor.cleanParent(masterServices, parent, r));
    Path parentDir = new Path(tabledir, parent.getEncodedName());
    ProcedureTestingUtility.waitAllProcedures(masterServices.getMasterProcedureExecutor());
    assertTrue(!fs.exists(parentDir));

    // And now check to make sure that the files have actually been archived
    FileStatus[] archivedStoreFiles = fs.listStatus(storeArchive);
    assertArchiveEqualToOriginal(storeFiles, archivedStoreFiles, fs);

    // now add store files with the same names as before to check backup
    // enable archiving, make sure that files get archived
    addMockStoreFiles(2, this.masterServices, storedir);

    // Do the cleaning of the parent
    assertTrue(CatalogJanitor.cleanParent(masterServices, parent, r));
    // Cleanup procedure runs async. Wait till it done.
    ProcedureTestingUtility.waitAllProcedures(masterServices.getMasterProcedureExecutor());
    assertTrue(!fs.exists(parentDir));

    // and now check to make sure that the files have actually been archived
    archivedStoreFiles = fs.listStatus(storeArchive);
    assertArchiveEqualToOriginal(storeFiles, archivedStoreFiles, fs, true);
  }

  @Test
  public void testAlreadyRunningStatus() throws Exception {
    int numberOfThreads = 2;
    List<Integer> gcValues = new ArrayList<>();
    Thread[] threads = new Thread[numberOfThreads];
    for (int i = 0; i < numberOfThreads; i++) {
      threads[i] = new Thread(() -> {
        try {
          gcValues.add(janitor.scan());
        } catch (IOException e) {
          throw new RuntimeException(e);
        }
      });
    }
    for (int i = 0; i < numberOfThreads; i++) {
      threads[i].start();
    }
    for (int i = 0; i < numberOfThreads; i++) {
      threads[i].join();
    }
    assertTrue("One janitor.scan() call should have returned -1", gcValues.contains(-1));
  }

  private FileStatus[] addMockStoreFiles(int count, MasterServices services, Path storedir)
    throws IOException {
    // get the existing store files
    FileSystem fs = services.getMasterFileSystem().getFileSystem();
    fs.mkdirs(storedir);
    // create the store files in the parent
    for (int i = 0; i < count; i++) {
      Path storeFile = new Path(storedir, "_store" + i);
      FSDataOutputStream dos = fs.create(storeFile, true);
      dos.writeBytes("Some data: " + i);
      dos.close();
    }
    LOG.debug("Adding " + count + " store files to the storedir:" + storedir);
    // make sure the mock store files are there
    FileStatus[] storeFiles = fs.listStatus(storedir);
    assertEquals("Didn't have expected store files", count, storeFiles.length);
    return storeFiles;
  }

  private String setRootDirAndCleanIt(final HBaseTestingUtil htu, final String subdir)
    throws IOException {
    Path testdir = htu.getDataTestDir(subdir);
    FileSystem fs = FileSystem.get(htu.getConfiguration());
    if (fs.exists(testdir)) assertTrue(fs.delete(testdir, true));
    CommonFSUtils.setRootDir(htu.getConfiguration(), testdir);
    return CommonFSUtils.getRootDir(htu.getConfiguration()).toString();
  }

  private Path createReferences(final MasterServices services, final TableDescriptor td,
    final RegionInfo parent, final RegionInfo daughter, final byte[] midkey, final boolean top)
    throws IOException {
    Path rootdir = services.getMasterFileSystem().getRootDir();
    Path tabledir = CommonFSUtils.getTableDir(rootdir, parent.getTable());
    Path storedir =
      HRegionFileSystem.getStoreHomedir(tabledir, daughter, td.getColumnFamilies()[0].getName());
    Reference ref =
      top ? Reference.createTopReference(midkey) : Reference.createBottomReference(midkey);
    long now = EnvironmentEdgeManager.currentTime();
    // Reference name has this format: StoreFile#REF_NAME_PARSER
    Path p = new Path(storedir, Long.toString(now) + "." + parent.getEncodedName());
    FileSystem fs = services.getMasterFileSystem().getFileSystem();
    HRegionFileSystem regionFS =
      HRegionFileSystem.create(services.getConfiguration(), fs, tabledir, daughter);
    StoreContext storeContext =
      StoreContext.getBuilder().withColumnFamilyDescriptor(td.getColumnFamilies()[0])
        .withFamilyStoreDirectoryPath(storedir).withRegionFileSystem(regionFS).build();
    StoreFileTracker sft =
      StoreFileTrackerFactory.create(services.getConfiguration(), false, storeContext);
    sft.createReference(ref, p);
    return p;
  }

  private Result createResult(final RegionInfo parent, final RegionInfo a, final RegionInfo b)
    throws IOException {
    return MetaMockingUtil.getMetaTableRowResult(parent, null, a, b);
  }
}
