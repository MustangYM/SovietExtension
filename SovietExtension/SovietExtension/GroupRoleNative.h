#pragma once
#include <algorithm>
#include <string>
#import <Foundation/Foundation.h>
#include <cstring>
#include <set>
#include <vector>
#include <mach/mach_vm.h>
namespace ym::group_info {
inline bool profileMemberID(const std::string &s){
    return !s.empty() && s.size()<=128 &&
        std::all_of(s.begin(),s.end(),[](unsigned char c){
            return (c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.';
        });
}
struct NativeRoomSources {
    std::string group;
    uint32_t version=0;
    std::string owner;
    std::set<std::string> members;
    std::set<std::string> admins;
};
namespace native_source {
inline bool bytes(uintptr_t p,void *v,size_t n){
    if(!p||!v||!n)return false;mach_vm_size_t copied=0;
    return mach_vm_read_overwrite(mach_task_self(),p,n,reinterpret_cast<mach_vm_address_t>(v),&copied)==KERN_SUCCESS && copied==n;
}
template<class T>inline bool read(uintptr_t p,T &v){return bytes(p,&v,sizeof(v));}
// ARM libc++ alternate layout (WeChat Room / ChatroomMember): size in last
// byte, long bit in that byte's MSB. Same reader as YMNSStringFromLibcppStringObject.
inline bool text(uintptr_t p,size_t bound,std::string &out){
    uint8_t h[24],again[24];if(!bytes(p,h,24))return false;
    int8_t flag=(int8_t)h[23];
    if(flag>=0){
        size_t n=(uint8_t)flag;
        if(!n||n>23||n>bound)return false;
        out.assign(reinterpret_cast<char*>(h),n);
        return bytes(p,again,24)&&!memcmp(h,again,24)&&out.find('\0')==out.npos;
    }
    uintptr_t data=0;size_t n=0;memcpy(&data,h,8);memcpy(&n,h+8,8);
    if(!data||!n||n>bound)return false;out.assign(n,'\0');
    return bytes(data,out.data(),n)&&bytes(p,again,24)&&!memcmp(h,again,24)&&out.find('\0')==out.npos;
}
inline bool groupID(const std::string &s){return s.size()>9&&s.size()<=128&&s.ends_with("@chatroom")&&profileMemberID(s.substr(0,s.size()-9));}
// Room.ext_buffer is a byte vector, not a libc++ string. Hold the Room owner
// and verify its begin/end/capacity again after copying the protobuf payload.
inline bool blob(uintptr_t p,size_t bound,std::string &out){
    uintptr_t h[3],again[3];if(!bytes(p,h,sizeof(h)))return false;
    if(!h[0]||h[1]<=h[0]||h[2]<h[1]||h[1]-h[0]>bound)return false;
    size_t n=h[1]-h[0];out.assign(n,'\0');
    return bytes(h[0],out.data(),n)&&bytes(p,again,sizeof(again))&&!memcmp(h,again,sizeof(h));
}
// ARM 269079 / 270353 ChatroomMemberLocalData, same Room offsets GroupExit uses:
// group id inline at room+8, version +0x7c, member list +0x58/+0x60, total +0xd8.
// Member username pointer +8, protobuf field 3 uint32 +0x20, presence bits +0x28.
// Parser presence bit 2 (value 4) and copy-ctor bit 1 (value 2) both mean +0x20
// is set. Alloc only zeros one byte of +0x20,
// so flag 0x800 is ignored unless (bits & 6). 0x800 is chatroom_member_flag admin.
//
// Room header matches WCDB chatroom: username +8, owner +0x20, ext_buffer +0x38.
// Owner is kept only when it is a member id. A missing/unreadable owner does not
// reject the room. Live ContactMgr CContact is not packed_WCContact, so +0x140 is
// not m_nsChatRoomAdminList; copyGroupAdmins stays a last fallback.
// Member +0x2c is not local_type. HideMention's self-admin flag is not a
// per-sender role.
inline void takeOwner(const std::string &owner,NativeRoomSources &v){
    if(profileMemberID(owner)&&v.members.contains(owner))v.owner=owner;
}
inline void takeMemberAdmin(const std::string &id,NativeRoomSources &v){
    if(profileMemberID(id)&&v.members.contains(id)&&id!=v.owner)v.admins.insert(id);
}
inline void takeAdmins(const std::string &raw,NativeRoomSources &v){
    std::set<std::string> admins;
    for(size_t i=0;i<raw.size();){
        while(i<raw.size()&&(raw[i]==';'||raw[i]==','||raw[i]==' '||raw[i]=='\n'))++i;
        size_t j=i;
        while(j<raw.size()&&raw[j]!=';'&&raw[j]!=','&&raw[j]!='\n')++j;
        std::string id=raw.substr(i,j-i);
        while(!id.empty()&&id.back()==' ')id.pop_back();
        if(profileMemberID(id)&&v.members.contains(id)&&id!=v.owner)admins.insert(std::move(id));
        i=j==i?j+1:j;
    }
    if(admins.empty()||admins.size()==v.members.size())return;
    v.admins=std::move(admins);
}
// Packed_WCContact m_nsChatRoomAdminList at +0x140. Live CContact from
// ContactMgr is a different object; only call when admins are still empty.
inline bool copyGroupAdmins(uintptr_t contact,NativeRoomSources &v){
    std::string name,raw;
    if(!contact||!text(contact+8,128,name)||name!=v.group)return false;
    if(!text(contact+0x140,4096,raw)||raw.empty())return false;
    takeAdmins(raw,v);
    return true;
}
inline bool pbVarint(const uint8_t *&p,const uint8_t *end,uint64_t &v){
    v=0;unsigned shift=0;
    while(p<end&&shift<=63){
        uint8_t b=*p++;
        v|=uint64_t(b&0x7f)<<shift;
        if((b&0x80)==0)return true;
        shift+=7;
    }
    return false;
}
inline bool pbSkip(uint64_t tag,const uint8_t *&p,const uint8_t *end){
    switch(tag&7){
    case 0:{uint64_t v;return pbVarint(p,end,v);}
    case 1:if(end-p<8)return false;p+=8;return true;
    case 2:{uint64_t n;if(!pbVarint(p,end,n)||uint64_t(end-p)<n)return false;p+=size_t(n);return true;}
    case 5:if(end-p<4)return false;p+=4;return true;
    default:return false;
    }
}
inline void parseExtMember(const uint8_t *p,const uint8_t *end,NativeRoomSources &v){
    std::string username;uint32_t flag=0;bool hasFlag=false;
    while(p<end){
        uint64_t tag=0;if(!pbVarint(p,end,tag))return;
        uint32_t field=uint32_t(tag>>3),wire=uint32_t(tag&7);
        if(field==1&&wire==2){
            uint64_t n=0;if(!pbVarint(p,end,n)||uint64_t(end-p)<n)return;
            username.assign(reinterpret_cast<const char*>(p),size_t(n));p+=size_t(n);
        }else if(field==3&&wire==0){
            uint64_t val=0;if(!pbVarint(p,end,val))return;
            flag=uint32_t(val);hasFlag=true;
        }else if(!pbSkip(tag,p,end))return;
    }
    if(hasFlag&&(flag&0x800))takeMemberAdmin(username,v);
}
// Room+0x38 is WCDB chatroom.ext_buffer: ChatRoomData field 1 repeated members,
// nested field 3 = chatroom_member_flag. Only used when the member walk found none.
inline void copyExtAdmins(uintptr_t room,NativeRoomSources &v){
    std::string buf;
    if(!blob(room+0x38,512u*1024u,buf)||buf.empty())return;
    const uint8_t *p=reinterpret_cast<const uint8_t*>(buf.data());
    const uint8_t *end=p+buf.size();
    while(p<end){
        uint64_t tag=0;if(!pbVarint(p,end,tag))return;
        if((tag>>3)==1&&(tag&7)==2){
            uint64_t n=0;if(!pbVarint(p,end,n)||uint64_t(end-p)<n)return;
            parseExtMember(p,p+size_t(n),v);p+=size_t(n);
        }else if(!pbSkip(tag,p,end))return;
    }
}
inline bool copyRoom(uintptr_t room,const std::string &group,const std::string &self,NativeRoomSources &out){
    out={};NativeRoomSources v;uintptr_t begin=0;int32_t count=0;uint64_t total=0;
    if(!room||!groupID(group)||!profileMemberID(self)||
       !text(room+8,128,v.group)||v.group!=group||!read(room+0x7c,v.version)||!v.version||
       !read(room+0x58,begin)||!read(room+0x60,count)||count<=0||count>20000||!begin||!read(room+0xd8,total)||total!=uint64_t(count))return false;
    std::vector<uintptr_t> items(count);if(!bytes(begin,items.data(),items.size()*8))return false;
    for(uintptr_t item:items){uintptr_t name=0;std::string member;uint32_t bits=0;
        if(!item||!read(item+8,name)||!text(name,128,member)||!profileMemberID(member)||!v.members.insert(member).second||!read(item+0x28,bits))return false;
        if(bits&6){uint32_t flag=0;if(read(item+0x20,flag)&&(flag&0x800))takeMemberAdmin(member,v);}
    }
    if(!v.members.contains(self))return false;
    std::string owner;
    if(text(room+0x20,128,owner))takeOwner(owner,v);
    if(!v.owner.empty())v.admins.erase(v.owner);
    if(v.admins.empty())copyExtAdmins(room,v);
    if(!v.owner.empty())v.admins.erase(v.owner);
    out=std::move(v);return true;
}
}
}
bool YMCopyCachedGroupRoles(const std::string &group, const std::string &self, ym::group_info::NativeRoomSources &out);
