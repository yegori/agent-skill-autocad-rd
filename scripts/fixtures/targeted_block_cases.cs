using System;
using System.Collections.Generic;
using System.Reflection;
using System.Web.Script.Serialization;
using Autodesk.AutoCAD.DatabaseServices;
class TargetedBlockCases {
 static string Sha=new string('1',64);
 static void Check(bool ok,string message){if(!ok)throw new System.Exception(message);}
 static object Call(string method,params object[] args){return typeof(RdDependencyProbe).GetMethod(method,BindingFlags.NonPublic|BindingFlags.Static).Invoke(null,args);}
 static Dictionary<string,object> Data(object o){var j=new JavaScriptSerializer();j.MaxJsonLength=16*1024*1024;return (Dictionary<string,object>)j.DeserializeObject(j.Serialize(o));}
 static Dictionary<string,string> Request(){return new Dictionary<string,string>{{"target_reference","a1"},{"target_block","b2"},{"expected_source_sha256",Sha}};}
 class Scene {
  public Database db=new Database(false,true);public Transaction tr=new Transaction();
  public BlockTableRecord owner=new BlockTableRecord{Number=0x10,IsLayout=true},block=new BlockTableRecord{Number=0xB2};
  public BlockReference insert=new BlockReference{Number=0xA1},nested=new BlockReference{Number=0xF0};
  public AttributeReference attr=new AttributeReference{Number=0xF2}; public DBText text=new DBText{Number=0xC3};
  public Scene(){
   var layout=new Layout{Number=0x11};owner.LayoutId=layout.ObjectId;insert.OwnerId=owner.ObjectId;insert.BlockTableRecord=block.ObjectId;
   text.OwnerId=block.ObjectId;nested.OwnerId=block.ObjectId;attr.OwnerId=nested.ObjectId;
   // Unresolved dependent edge is captured, never followed. No font/layer records are available.
   nested.BlockTableRecord=new BlockTableRecord{Number=0x99}.ObjectId;
   text.TextStyleId=attr.TextStyleId=new TextStyleTableRecord{Number=0xD4}.ObjectId;
   nested.AttributeCollection.Add(attr.ObjectId);owner.Items.Add(insert.ObjectId);block.Items.Add(text.ObjectId);block.Items.Add(nested.ObjectId);
   foreach(var o in new DBObject[]{owner,block,insert,text,nested,attr,layout})db.Objects[o.ObjectId.Handle.ToString()]=o;
  }
  public Dictionary<string,object> Read(){return Data(Call("ReadTargeted",db,tr,Call("ParseTargetRequest",Request(),Sha)));}
 }
 static void Parser(){
  Check(Call("ParseTargetRequest",new Dictionary<string,string>(),Sha)==null,"default must opt out");
  var cases=new List<Dictionary<string,string>>();var incomplete=Request();incomplete.Remove("target_block");cases.Add(incomplete);
  foreach(var bad in new[]{"0","01","-1","A*","A1\n","8000000000000000","FFFFFFFFFFFFFFFF","C:1"}){var r=Request();r["target_reference"]=bad;cases.Add(r);}
  var wrong=Request();wrong["expected_source_sha256"]=new string('2',64);cases.Add(wrong);
  var invalid=Request();invalid["expected_source_sha256"]="notsha";cases.Add(invalid);
  foreach(var r in cases){bool failed=false;try{Call("ParseTargetRequest",r,Sha);}catch(TargetInvocationException e){failed=e.InnerException is InvalidOperationException;}Check(failed,"invalid request accepted");}
  Console.WriteLine("OK: option off, strict complete request/positive canonical hex/source SHA parser");
 }
 static void Happy(){
  var s=new Scene();s.text.Visible=false;var r=s.Read();Check((string)r["status"]=="observed_partial" && (bool)r["link_verified"],"edge not verified");
  Check((string)r["source_sha256"]==Sha && (string)r["requested_reference"]=="A1" && (string)r["requested_block"]=="B2","provenance");
  Check(!(bool)r["complete"] && !(bool)r["truncated"] && (string)r["paper_reachability"]=="UNKNOWN","false closure");
  Check((int)r["opened_btr_count"]==2 && (int)r["entity_count"]==4,"counts");
  Check((string)((Dictionary<string,object>)r["owner_container"])["space"]=="paper" && (string)((Dictionary<string,object>)r["owner_container"])["capture"]=="metadata_only","owner context");
  Check((string)r["definition_scan"]=="enumerated_target_only","scan provenance");
  var rows=(object[])r["observations"];Check(rows.Length==3,"target subset");
  Check(!(bool)((Dictionary<string,object>)rows[0])["entity_visible"] && (string)((Dictionary<string,object>)rows[0])["plot_visibility"]=="UNKNOWN","visible flag conflated with plot proof");
  var attr=(Dictionary<string,object>)((Dictionary<string,object>)rows[2])["reference"];
  Check((string)attr["owner_handle"]=="F0" && (string)attr["parent_insert_handle"]=="F0" && (string)attr["container_handle"]=="B2","attribute provenance");
  Check(String.Join(",",s.db.Lookups)=="A1,B2,10" && !s.tr.Opened.Contains("99") && !s.tr.Opened.Contains("D4"),"dependency recursed or fonts resolved");
  Check(s.owner.Enumerations==0 && s.block.Enumerations==1,"owner/full model repeated");
  Console.WriteLine("OK: same-DB exact link/type/paper context/attrs/layer-visible metadata, no recursive/external/font lookup");
 }
 static void Failures(){
  foreach(var mode in new[]{"missing","null","erased","wrongref","derivedref","wrongtarget","link","external","externalowner","owner","entityowner","attrowner"}){
   var s=new Scene();
   if(mode=="missing" || mode=="null"){s.db.Objects.Remove("B2");s.db.MissingNull=mode=="null";}
   if(mode=="erased")s.block.Erased=true;
   if(mode=="wrongref")s.db.Objects["A1"]=new DBText{Number=0xA1};
   if(mode=="derivedref")s.db.Objects["A1"]=new DerivedInsert{Number=0xA1};
   if(mode=="wrongtarget")s.db.Objects["B2"]=new DBText{Number=0xB2};
   if(mode=="link")s.insert.BlockTableRecord=s.nested.BlockTableRecord;
   if(mode=="external")s.block.IsFromExternalReference=true;
   if(mode=="externalowner")s.owner.IsDependent=true;
   if(mode=="owner")s.insert.OwnerId=new ObjectId();
   if(mode=="entityowner")s.text.OwnerId=s.owner.ObjectId;
   if(mode=="attrowner")s.attr.OwnerId=s.owner.ObjectId;
   var r=s.Read();Check((string)r["status"]=="needs_input" && !(bool)r["complete"],"false success "+mode);
   Check(r.ContainsKey("reference_resolution") && r.ContainsKey("target_resolution") && r.ContainsKey("reason"),"resolution evidence lost");
   if(mode!="entityowner" && mode!="attrowner")Check(s.block.Enumerations==0,"invalid/external definition read "+mode);
   if(mode=="wrongtarget")Check((int)r["entity_count"]==2,"resolved wrong-type entity count hidden");
   if(mode=="external")Check((string)r["definition_scan"]=="external_skipped","external omission provenance");
  }
  var unsupported=new Scene();var entity=new Entity{Number=0xC3,OwnerId=unsupported.block.ObjectId};unsupported.block.Items[0]=entity.ObjectId;
  var u=unsupported.Read();var first=(Dictionary<string,object>)((object[])u["observations"])[0];
  Check((string)((Dictionary<string,object>)first["reference"])["kind"]=="unsupported_entity","unsupported lost");
  Console.WriteLine("OK: missing/null/erased/wrong exact types/derived/link/external/owner failures, unsupported retained UNKNOWN");
 }
 class DerivedInsert:BlockReference {}
 static void Cap(){
  var s=new Scene();s.block.Items.Clear();
  for(int i=0;i<20001;i++){var e=new Entity{Number=0x1000+i,OwnerId=s.block.ObjectId};s.block.Items.Add(e.ObjectId);}
  var r=s.Read();Check((bool)r["truncated"] && (int)r["entity_count"]==20000 && s.tr.Entities==20000,"entity cap raised");
  Check(((object[])r["observations"]).Length==19999 && (int)r["max_blocks"]==2048 && (int)r["max_entities"]==20000 && (string)r["definition_scan"]=="capped_target_only","caps changed");
  s=new Scene();s.block.Items.Clear();for(int i=0;i<19998;i++)s.block.Items.Add(new Entity{Number=0x1000+i,OwnerId=s.block.ObjectId}.ObjectId);
  s.block.Items.Add(s.nested.ObjectId);r=s.Read();Check((bool)r["truncated"] && s.tr.Entities==20000 && !s.tr.Opened.Contains("F2"),"attribute cap escaped");
  Console.WriteLine("OK: unchanged 2048/20000 limits include requested reference and attributes, no cap increase");
 }
 static void DefaultCompatibility(){
  var s=new Scene();var table=new BlockTable{s.owner.ObjectId,s.block.ObjectId};
  var r=Data(Call("ReadUsage",s.tr,table));
  Check((int)r["schema_version"]==1 && (string)r["coverage"]=="bounded_local_definition_references" && (string)r["traversal"]=="definitions_once_no_recursion","default shape changed");
  Check(!r.ContainsKey("targeted_block") && ((object[])r["observations"]).Length==4 && ((object[])r["containers"]).Length==2,"default capture changed");
  Console.WriteLine("OK: narrow unchanged-default schema/capture fixture (not old full suite)");
 }
 static int Main(){try{Parser();Happy();Failures();Cap();DefaultCompatibility();return 0;}catch(System.Exception e){Console.Error.WriteLine(e);return 1;}}
}
