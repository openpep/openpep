// SPDX-License-Identifier: AGPL-3.0-or-later
import {readFile} from 'node:fs/promises';
import {PDFName, rgb, pushGraphicsState, popGraphicsState, concatTransformationMatrix} from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';

export const certificateName = name => String(name || '').replace(/:\s*\d{11,14}\s*$/, '').replace(/[\x00-\x1f\x7f]/g, '').trim().slice(0,160);

// Fractions refer to the visible, rotated crop box, as displayed by PDF.js.
// Paint BEFORE reserving the cryptographic signature; never change signed bytes.
export async function drawAppearance(doc, appearance) {
  const {page: number,x,y,width,height,name} = appearance;
  if (!Number.isInteger(number) || number < 1 || number > doc.getPageCount() || ![x,y,width,height].every(Number.isFinite) ||
      x < 0 || y < 0 || width <= 0 || height <= 0 || x + width > 1.000001 || y + height > 1.000001 || !certificateName(name)) throw Error('Posição da assinatura inválida.');
  const page = doc.getPage(number - 1), media = page.getMediaBox(), crop = page.getCropBox();
  const left=Math.max(media.x,crop.x),bottom=Math.max(media.y,crop.y),right=Math.min(media.x+media.width,crop.x+crop.width),top=Math.min(media.y+media.height,crop.y+crop.height);
  const w=right-left,h=top-bottom,rotation=((page.getRotation().angle % 360)+360)%360;
  if (![0,90,180,270].includes(rotation) || w<=0 || h<=0) throw Error('Formato de página não suportado.');
  const dw=rotation%180 ? h:w, dh=rotation%180 ? w:h, sw=width*dw,sh=height*dh;
  if (sw<110 || sw>400 || Math.abs(sh/sw-72/220)>.005) throw Error('Tamanho da assinatura inválido.');
  const transforms={0:[1,0,0,1,left,bottom],90:[0,1,-1,0,right,bottom],180:[-1,0,0,-1,right,top],270:[0,-1,1,0,left,top]};
  const scale=sw/220, sx=x*dw, sy=(1-y-height)*dh;
  doc.registerFontkit(fontkit);
  const [font,logo]=await Promise.all([
    doc.embedFont(await readFile(new URL('../assets/fonts/pdf/inter-400-latin.ttf',import.meta.url)),{subset:true}),
    doc.embedPng(await readFile(new URL('../assets/openpep-mark.png',import.meta.url))),
  ]);
  const c=rgb(.13,.23,.29),blue=rgb(.04,.37,.55);
  page.pushOperators(pushGraphicsState(),concatTransformationMatrix(...transforms[rotation]));
  page.drawRectangle({x:sx,y:sy,width:sw,height:sh,color:rgb(1,1,1),borderColor:rgb(.65,.74,.79),borderWidth:.6*scale});
  page.drawImage(logo,{x:sx+8*scale,y:sy+25*scale,width:24*scale,height:24*scale});
  const tx=sx+40*scale,tw=170*scale;
  page.drawText('Assinado digitalmente por',{x:tx,y:sy+58*scale,size:7*scale,font,color:c});
  let size=9*scale,lines=[];
  const words=certificateName(name).split(/\s+/);
  const wrap=()=>{lines=[''];for(const word of words){const last=lines.length-1,candidate=[lines[last],word].filter(Boolean).join(' ');if(font.widthOfTextAtSize(candidate,size)>tw && lines[last])lines.push(word);else lines[last]=candidate;}};
  wrap(); if(lines.length>3 || lines.some(line=>font.widthOfTextAtSize(line,size)>tw)){size=7*scale;wrap();}
  if(lines.length>3 || lines.some(line=>font.widthOfTextAtSize(line,size)>tw)) throw Error('Nome do certificado excede o espaço da assinatura.');
  lines.forEach((line,i)=>page.drawText(line,{x:tx,y:sy+(44-i*10)*scale,size,font,color:c}));
  page.drawText('VIDaaS · OpenPEP-Rx',{x:tx,y:sy+9*scale,size:7*scale,font,color:blue});
  page.pushOperators(popGraphicsState());
  return page;
}
