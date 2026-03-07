  use std::io::{self,Read};
  fn main(){
  let mut s=String::new();
  io::stdin().read_to_string(&mut s).unwrap();
  let s=s.trim().as_bytes();
  let(mut mx,mut c)=(1usize,1usize);
  for i in 1..s.len(){if s[i]==s[i-1]{c+=1;}else{c=1;}if c>mx{mx=c;}}
  println!("{}",mx);
  }

