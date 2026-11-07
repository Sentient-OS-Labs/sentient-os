import AppKit
import SQLite3

@main enum SummaryConversationTests {
 static var count = 0
 static func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(),label);count += 1 }
 static func n(_ parent:Int,_ role:String,id:String="",classes:[String]=[],description:String="",value:String="",title:String="",subrole:String="",domID:String="",y:Double=0,h:Double=30)->SummaryConversation.Node {
  .init(parent:parent,role:role,id:id,classes:classes,description:description,value:value,frame:CGRect(x:0,y:y,width:500,height:h),title:title,subrole:subrole,domID:domID)
 }
 static func sql(_ path:String,_ text:String) {
  var db:OpaquePointer?;precondition(sqlite3_open(path,&db)==SQLITE_OK);defer{sqlite3_close(db)}
  precondition(sqlite3_exec(db,text,nil,nil,nil)==SQLITE_OK,"fixture SQL")
 }
 static func main() throws {
  let rows = [n(-1,"AXWindow",h:500),n(0,"AXGroup",id:"ChatMessagesTableView",h:500),
   n(0,"AXButton",id:"NavigationBar_HeaderViewButton",description:"Chosen chat",y:0,h:40),
   n(0,"AXTextArea",id:"ChatBar_ComposerTextView",description:"DRAFT POISON",y:480),
   n(1,"AXStaticText",id:"WAMessageBubbleTableViewCell",description:"OLD ABOVE VIEWPORT",y:0,h:20),
   n(1,"AXStaticText",id:"WAMessageBubbleTableViewCell",description:"FIRST VISIBLE MESSAGE",y:80),
   n(1,"AXStaticText",id:"WAMessageBubbleTableViewCell",description:"NEWER OFFSCREEN MESSAGE",y:700),
   n(0,"AXStaticText",description:"OTHER CHAT POISON",y:100)]
  let selected=SummaryConversation.select(rows,app:.whatsapp)!
  check(selected.title=="Chosen chat","active chat title")
  check(selected.text=="FIRST VISIBLE MESSAGE\nNEWER OFFSCREEN MESSAGE","visible onward, including below viewport")
  check(selected.offscreen==1,"offscreen coverage measured")
  var unread=rows;unread[4]=n(1,"AXHeading",description:"3 unread messages",y:0,h:20)
  check(SummaryConversation.select(unread,app:.whatsapp)!.text==selected.text,"visible boundary takes precedence over unread separator")
  var none=rows;none[5].frame=CGRect(x:0,y:700,width:500,height:30)
  check(SummaryConversation.select(none,app:.whatsapp)==nil,"no visible anchor does not expose whole history")
  let im=[n(-1,"AXWindow",h:500),n(0,"AXGroup",id:"TranscriptCollectionView",h:500),
   n(0,"AXButton",id:"ConversationTitle",description:"Dana",y:0,h:40),
   n(1,"AXGroup",description:"Dana, Keep the launch Friday, 10 AM",y:80),
   n(3,"AXTextArea",id:"CKBalloonTextView",value:"Keep the launch Friday",y:80),
   n(0,"AXTextField",id:"messageBodyField",value:"UNSENT DRAFT",y:450)]
  let message=SummaryConversation.select(im,app:.messages)!
  check(message.items.count==1 && message.text.contains("Dana,"),"sender retained without duplicate balloon")
  check(message.items.first?.anchor=="Keep the launch Friday","plain body anchor")
  let web=[n(-1,"AXWindow",h:500),n(0,"AXGroup",classes:["epitaxy-chat-panel-body"],h:300),
   n(1,"AXGroup",description:"Message 1",subrole:"AXDocumentArticle",h:1),n(2,"AXStaticText",value:"OLDER MESSAGE",h:1),
   n(1,"AXGroup",description:"Message 2",subrole:"AXDocumentArticle",h:300),
   n(4,"AXStaticText",value:"BEGINNING ABOVE SCREEN",h:1),n(4,"AXStaticText",value:"VISIBLE END",y:20),
   n(1,"AXGroup",description:"Message 3",subrole:"AXDocumentArticle",y:300,h:0),n(7,"AXStaticText",value:"NEWER",y:300,h:0),
   n(0,"AXStaticText",value:"SIDEBAR",y:30)]
  let claude=SummaryConversation.select(web,app:.claude)!
  check(claude.text.contains("BEGINNING ABOVE SCREEN") && claude.text.contains("VISIBLE END") && claude.text.contains("NEWER"),"Claude retains complete partly visible message and subsequent messages")
  check(!claude.text.contains("OLDER MESSAGE") && !claude.text.contains("SIDEBAR"),"Claude excludes earlier complete messages and sidebar")
  let cg=[n(-1,"AXWindow",h:500),n(0,"AXGroup",classes:["thread-scroll-container"],description:"Conversation",h:300),
   n(1,"AXHeading",classes:["sr-only"],title:"You said:",h:1),n(1,"AXStaticText",value:"OLD USER MESSAGE",h:1),
   n(1,"AXHeading",classes:["sr-only"],title:"ChatGPT said:",h:1),n(1,"AXStaticText",value:"ABOVE SCREEN SAME MESSAGE",h:1),
   n(1,"AXStaticText",value:"VISIBLE",y:20),n(1,"AXHeading",classes:["sr-only"],title:"You said:",y:300,h:0),
   n(1,"AXStaticText",value:"NEWER",y:300,h:0),n(1,"AXGroup",classes:["group/activity-header"],y:100),n(9,"AXStaticText",value:"TOOL COMMAND POISON",y:100)]
  let chat=SummaryConversation.select(cg,app:.chatgpt)!
  check(chat.text.contains("ABOVE SCREEN SAME MESSAGE") && chat.text.contains("NEWER"),"ChatGPT uses message boundaries, not first visible text node")
  check(!chat.text.contains("OLD USER MESSAGE") && !chat.text.contains("TOOL COMMAND POISON"),"ChatGPT excludes earlier messages and tool chrome")
  let sl=[n(-1,"AXWindow",h:500),n(0,"AXGroup",classes:["p-message_pane"],h:300),
   n(1,"AXList",classes:["sr-only"],description:"Project channel",h:0),
   n(2,"AXGroup",classes:["c-virtual_list__item"],domID:"message-list_1",h:1),n(3,"AXGroup",classes:["c-message_kit__hover"],h:1),n(4,"AXStaticText",value:"OLD SLACK",h:1),
   n(2,"AXGroup",classes:["c-virtual_list__item"],domID:"message-list_2",h:100),n(6,"AXGroup",classes:["c-message_kit__hover"],h:100),
   n(7,"AXButton",classes:["c-message__sender_button"],title:"Dana",h:1),n(7,"AXStaticText",value:"FULL SLACK BEGINNING",h:1),n(7,"AXStaticText",value:"VISIBLE SLACK END",y:20),
   n(7,"AXGroup",classes:["c-message_kit__reaction_bar"],description:"Reactions",y:100),n(11,"AXStaticText",value:"REACTION POISON",y:100)]
  let slack=SummaryConversation.select(sl,app:.slack)!
  check(slack.text.contains("Dana") && slack.text.contains("FULL SLACK BEGINNING") && slack.text.contains("VISIBLE SLACK END"),"Slack preserves sender and full first visible message")
  check(!slack.text.contains("OLD SLACK") && !slack.text.contains("REACTION POISON"),"Slack excludes old messages and reactions")
  check(SummaryConversation.clean("\u{200e}hello\u{2069}")=="hello","direction markers normalized")

  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let wa=root.appendingPathComponent("wa.sqlite")
  sql(wa.path,"""
   CREATE TABLE ZWACHATSESSION(Z_PK INTEGER PRIMARY KEY,ZPARTNERNAME TEXT,ZSESSIONTYPE INTEGER);
   CREATE TABLE ZWAGROUPMEMBER(Z_PK INTEGER PRIMARY KEY,ZCONTACTNAME TEXT);
   CREATE TABLE ZWAMESSAGE(Z_PK INTEGER PRIMARY KEY,ZCHATSESSION INTEGER,ZMESSAGEDATE REAL,ZISFROMME INTEGER,ZTEXT TEXT,ZPUSHNAME TEXT,ZGROUPMEMBER INTEGER);
   INSERT INTO ZWACHATSESSION VALUES(1,'Chosen chat',0),(2,'Other chat',0);
   INSERT INTO ZWAMESSAGE VALUES(1,1,100,1,'First visible anchor',NULL,NULL),(2,1,200,0,'Second visible anchor',NULL,NULL),(3,1,300,0,'Newer offscreen decision Friday',NULL,NULL),(4,2,400,0,'OTHER CHAT POISON',NULL,NULL);
   """)
  let items=[SummaryConversation.Item(text:"Your message, First visible anchor, 10 AM",anchor:"First visible anchor",frame:nil),.init(text:"message, Second visible anchor, 11 AM",anchor:"Second visible anchor",frame:nil)]
  let before=try Data(contentsOf:wa)
  let extra=SummaryConversationStore.newerMessages(app:.whatsapp,title:"Chosen chat",items:items,database:wa)!
  check(extra.lines.count==1 && extra.lines[0].contains("Newer offscreen decision Friday"),"WhatsApp extends only the matched chat")
  let after=try Data(contentsOf:wa)
  check(after==before,"message database stays unchanged")
  check(SummaryConversationStore.newerMessages(app:.whatsapp,title:"Other chat",items:items,database:wa)==nil,"wrong chat cannot match")
  check(SummaryConversationStore.newerMessages(app:.whatsapp,title:"Chosen chat",items:Array(items.prefix(1)),database:wa)==nil,"one anchor cannot expose a conversation")
  sql(wa.path,"WITH RECURSIVE nums(n) AS (SELECT 10 UNION ALL SELECT n+1 FROM nums WHERE n<3010) INSERT INTO ZWAMESSAGE SELECT n,1,n+500,0,'Continuation message '||n,NULL,NULL FROM nums; UPDATE ZWAMESSAGE SET ZTEXT='FINAL NEWEST DECISION' WHERE Z_PK=3010;")
  let large=SummaryConversationStore.newerMessages(app:.whatsapp,title:"Chosen chat",items:items,database:wa)!
  check(large.truncated && large.lines.last?.contains("FINAL NEWEST DECISION")==true,"oversized chats retain the latest messages with explicit truncation")
  sql(wa.path,"INSERT INTO ZWACHATSESSION VALUES(3,'Chosen chat',0); INSERT INTO ZWAMESSAGE VALUES(5,3,100,1,'First visible anchor',NULL,NULL),(6,3,200,0,'Second visible anchor',NULL,NULL);")
  check(SummaryConversationStore.newerMessages(app:.whatsapp,title:"Chosen chat",items:items,database:wa)==nil,"ambiguous name and anchors rejected")
  let ims=root.appendingPathComponent("messages.sqlite")
  sql(ims.path,"""
   CREATE TABLE message(ROWID INTEGER PRIMARY KEY,date INTEGER,is_from_me INTEGER,text TEXT,attributedBody BLOB,handle_id INTEGER,associated_message_type INTEGER,item_type INTEGER);
   CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);CREATE TABLE handle(ROWID INTEGER PRIMARY KEY,id TEXT);
   CREATE TABLE chat(ROWID INTEGER PRIMARY KEY,display_name TEXT,chat_identifier TEXT);INSERT INTO chat VALUES(1,'Dana','person@example.com');
   INSERT INTO handle VALUES(1,'person@example.com');INSERT INTO chat_handle_join VALUES(1,1);
   INSERT INTO message VALUES(1,1000000000,1,'First visible anchor',NULL,1,0,0),(2,2000000000,0,'Second visible anchor',NULL,1,0,0),(3,3000000000,0,'Newer iMessage decision Friday',NULL,1,0,0),(4,4000000000,0,'Tapback poison',NULL,1,2000,0);
   INSERT INTO chat_message_join VALUES(1,1),(1,2),(1,3),(1,4);
   """)
  let later=SummaryConversationStore.newerMessages(app:.messages,title:"Dana",items:items,database:ims)!
  check(later.lines.count==1 && later.lines[0].contains("Dana: Newer iMessage decision Friday"),"iMessage preserves sender and ignores tapbacks")
  check(SummaryConversationStore.newerMessages(app:.messages,title:"Different person",items:items,database:ims)==nil,"matching text cannot override a different chat identity")
  check(SummaryConversationStore.newerMessages(app:.messages,title:"Dana",items:Array(items.prefix(1)),database:ims)==nil,"iMessage requires two anchors")
  let blob=Data("NSString".utf8)+Data(repeating:0,count:5)+Data([5])+Data("hello".utf8)
  check(MessageBody.text(blob)=="hello","shared attributed-body decoder")
  check(MessageBody.text(Data([0,1,2]))==nil,"malformed body ignored")
  print("PASS: \(count) conversation boundary, identity and read-only store checks")
 }
}
