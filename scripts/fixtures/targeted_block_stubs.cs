// Entirely synthetic API surface. Never references/loads Autodesk binaries.
using System;
using System.Collections;
using System.Collections.Generic;
namespace Autodesk.AutoCAD.Runtime {
 public enum CommandFlags { Session }
 public class CommandMethodAttribute : Attribute { public CommandMethodAttribute(string n,CommandFlags f) {} }
 public class RXClass { public string Name="FAKE_RX_CLASS"; }
 public class Exception : System.Exception { public string ErrorStatus="fake_lookup_failure"; }
}
namespace Autodesk.AutoCAD.ApplicationServices.Core {
 public class Application { public static object GetSystemVariable(string n) { throw new System.Exception("host/font lookup forbidden in targeted fixture"); } }
}
namespace Autodesk.AutoCAD.DatabaseServices {
 public enum OpenMode { ForRead }
 public enum FileOpenMode { OpenForReadAndAllShare }
 public struct Handle { public long Value; public Handle(long n){Value=n;} public override string ToString(){return Value.ToString("X");} }
 public struct ObjectId {
  public DBObject Value; public bool IsNull {get{return Value==null;}} public bool IsErased {get{return Value!=null && Value.Erased;}}
  public Handle Handle {get{return new Handle(Value==null?0:Value.Number);}}
  public override int GetHashCode(){return Value==null?0:Value.GetHashCode();}
  public override bool Equals(object o){return o is ObjectId && ((ObjectId)o).Value==Value;}
  public static bool operator ==(ObjectId a,ObjectId b){return a.Value==b.Value;}
  public static bool operator !=(ObjectId a,ObjectId b){return a.Value!=b.Value;}
 }
 public class DBObject {
  public long Number; public bool Erased; public ObjectId OwnerId;
  public ObjectId ObjectId {get{return new ObjectId{Value=this};}}
  public Autodesk.AutoCAD.Runtime.RXClass GetRXClass(){return new Autodesk.AutoCAD.Runtime.RXClass();}
 }
 public class Entity:DBObject { public ObjectId LayerId; public string Layer="generic-layer"; public bool Visible=true; }
 public class DBText:Entity {public ObjectId TextStyleId;}
 public class AttributeDefinition:DBText {}
 public class AttributeReference:DBText {}
 public class MText:Entity {public ObjectId TextStyleId;}
 public class BlockReference:Entity {public ObjectId BlockTableRecord; public List<ObjectId> AttributeCollection=new List<ObjectId>();}
 public class BlockTableRecord:DBObject,IEnumerable<ObjectId> {
  public string Name="generic-block",PathName=""; public bool IsLayout,IsFromExternalReference,IsFromOverlayReference,IsDependent;
  public object XrefStatus="fake"; public ObjectId LayoutId; public List<ObjectId> Items=new List<ObjectId>(); public int Enumerations;
  public IEnumerator<ObjectId> GetEnumerator(){Enumerations++; return Items.GetEnumerator();} IEnumerator IEnumerable.GetEnumerator(){return GetEnumerator();}
 }
 public class BlockTable:DBObject,IEnumerable<ObjectId> {List<ObjectId> ids=new List<ObjectId>();public void Add(ObjectId id){ids.Add(id);}public IEnumerator<ObjectId> GetEnumerator(){return ids.GetEnumerator();}IEnumerator IEnumerable.GetEnumerator(){return GetEnumerator();}}
 public class TextStyleTable:BlockTable {}
 public class FontInfo {public string TypeFace="fake-not-resolved";}
 public class TextStyleTableRecord:DBObject {public string Name,FileName,BigFontFileName;public FontInfo Font=new FontInfo();}
 public class Layout:DBObject {public bool ModelType;public string LayoutName="generic-paper",CanonicalMediaName,PlotConfigurationName,CurrentStyleSheet;public int TabOrder;}
 public struct DBDictionaryEntry {public string Key;public ObjectId Value;}
 public class DBDictionary:DBObject,ListShim {public bool Contains(string k){return false;}public ObjectId GetAt(string k){throw new System.Exception("dictionary forbidden");}public IEnumerator GetEnumerator(){return new List<DBDictionaryEntry>().GetEnumerator();}}
 public interface ListShim:IEnumerable {}
 public class RasterImageDef:DBObject {public string SourceFileName;}
 public class UnderlayDefinition:DBObject {public string SourceFileName;}
 public class Transaction:IDisposable {
  public int Entities; public List<string> Opened=new List<string>();
  public DBObject GetObject(ObjectId id,OpenMode mode){if(id.IsNull || id.IsErased)throw new Autodesk.AutoCAD.Runtime.Exception();Opened.Add(id.Handle.ToString());if(id.Value is Entity)Entities++;return id.Value;}
  public void Dispose(){}
 }
 public class TransactionManager {public Transaction StartOpenCloseTransaction(){throw new System.Exception("Run/DB open forbidden in inert tests");}}
 public class Database:IDisposable {
  public Dictionary<string,DBObject> Objects=new Dictionary<string,DBObject>();public List<string> Lookups=new List<string>();public bool MissingNull;
  public Database(bool a,bool b){} public TransactionManager TransactionManager=new TransactionManager();
  public ObjectId GetObjectId(bool create,Handle h,int x){if(create)throw new System.Exception("create forbidden");Lookups.Add(h.ToString());DBObject o;if(Objects.TryGetValue(h.ToString(),out o))return o.ObjectId;if(MissingNull)return new ObjectId();throw new Autodesk.AutoCAD.Runtime.Exception();}
  public ObjectId BlockTableId {get{throw new System.Exception("full table scan forbidden in targeted path");}}
  public ObjectId TextStyleTableId {get{throw new System.Exception("font table forbidden");}}
  public ObjectId LayoutDictionaryId {get{throw new System.Exception("layout table scan forbidden");}}
  public ObjectId NamedObjectsDictionaryId {get{throw new System.Exception("asset scan forbidden");}}
  public void ReadDwgFile(string s,FileOpenMode m,bool a,string p){throw new System.Exception("real DB read forbidden");}
  public void CloseInput(bool b){throw new System.Exception("Run forbidden");} public void Dispose(){}
 }
}
